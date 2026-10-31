defmodule Mydia.Indexers.CardigannSearchEngine do
  @moduledoc """
  Core search engine that executes searches using parsed Cardigann definitions.

  This module handles:
  - Building search URLs from templates with variable substitution
  - Executing HTTP requests with proper headers, cookies, and rate limiting
  - FlareSolverr integration for Cloudflare-protected sites
  - Validating responses before passing to the result parser
  - Error handling for timeouts, rate limits, and invalid responses

  ## Search Flow

  1. **Build Search URL:** Apply query template with parameters
  2. **Build Request Params:** Construct query parameters
  3. **Execute HTTP Request:** Send request with headers, cookies, etc.
     - Direct first, with any cached Cloudflare clearance for the host
     - If Cloudflare challenges: solve through FlareSolverr, then repeat directly
  4. **Validate Response:** Check response is valid
  5. **Return Response:** Pass to result parser (handled by caller)

  ## FlareSolverr Integration

  FlareSolverr earns a clearance; it does not fetch the page:
  1. A request goes direct first. An indexer flagged as needing FlareSolverr
     skips this only when no clearance is cached for its host.
  2. On a Cloudflare challenge, FlareSolverr gets the bare URL and no cookies.
  3. The solution's cookies and user-agent are cached per host in
     `Mydia.Indexers.FlareSolverr.ClearanceCache` (memory only).
  4. The request is repeated directly and that response is parsed. Chrome's
     rendered page is only a fallback when the repeat is still challenged.

  ## URL Template Variables

  Cardigann definitions use Go-style template variables:
  - `{{ .Keywords }}` - Search query
  - `{{ .Query.Series }}` - TV show name
  - `{{ .Query.Season }}` - Season number
  - `{{ .Query.Ep }}` - Episode number
  - `{{ .Categories }}` - Category IDs

  ## Example

      definition = %Parsed{
        id: "1337x",
        search: %{
          paths: [%{path: "/search/{{ .Keywords }}/1/"}],
          ...
        },
        ...
      }

      opts = [query: "Ubuntu 22.04", categories: [2000]]
      {:ok, response} = CardigannSearchEngine.execute_search(definition, opts)
  """

  alias Mydia.Indexers.Cardigann.BlockPage
  alias Mydia.Downloads.Client.Helpers
  alias Mydia.Indexers.Cardigann.{FlareSolverrFlow, Links}
  alias Mydia.Indexers.Cardigann.TemplateContext
  alias Mydia.Indexers.Cardigann.LoggedOut
  alias Mydia.Indexers.Cardigann.Parity.Seam
  alias Mydia.Indexers.Cardigann.RequestHeaders
  alias Mydia.Indexers.Cardigann.SearchPaths
  alias Mydia.Indexers.Cardigann.SearchRequest
  alias Mydia.Indexers.Cardigann.SessionCookies
  alias Mydia.Indexers.CardigannDefinition.Parsed
  alias Mydia.Indexers.CardigannTemplate
  alias Mydia.Indexers.Adapter.Error
  alias Mydia.Indexers.FlareSolverr
  alias Mydia.Indexers.RateLimiter
  alias Mydia.Indexers.FlareSolverr.ClearanceCache

  require Logger

  # Interstitial titles are matched at any status: some challenges are served
  # with a 200, and a 403 page can omit the word "Cloudflare" entirely.
  @challenge_titles [
    "<title>Just a moment...</title>",
    "<title>Attention Required! | Cloudflare</title>",
    "<title>Please Wait... | Cloudflare</title>",
    "<title>DDoS-Guard</title>"
  ]

  @type search_opts :: [
          query: String.t(),
          categories: [integer()],
          season: integer() | nil,
          episode: integer() | nil,
          imdb_id: String.t() | nil,
          tmdb_id: integer() | nil,
          tvdb_id: integer() | nil,
          config: map() | nil,
          settings: [map()] | nil,
          base_url: String.t() | nil,
          on_promote: (String.t() -> term()) | nil,
          search_path: map() | nil,
          pin_base_url: boolean(),
          request_timeout_ms: pos_integer() | nil
        ]

  @type http_response :: %{
          required(:status) => integer(),
          # Req decodes a JSON response into a map or a list.
          required(:body) => String.t() | map() | list(),
          required(:headers) => [{String.t(), String.t()}],
          # The mirror that answered; set by execute_search/4.
          optional(:base_url) => String.t()
        }

  @type flaresolverr_opts :: %{
          optional(:enabled) => boolean(),
          optional(:definition_id) => binary()
        }

  @doc """
  Executes a search using the given Cardigann definition and search options.

  ## Parameters

  - `definition` - Parsed Cardigann definition
  - `opts` - Search options (query, categories, season, episode, etc.)
  - `user_config` - Optional user configuration (cookies, credentials)
  - `flaresolverr_opts` - Optional FlareSolverr configuration:
    - `:enabled` - Whether to use FlareSolverr for this indexer
    - `:definition_id` - Database ID of the indexer

  ## Returns

  - `{:ok, response}` - HTTP response ready for parsing
  - `{:ok, response, [{:flaresolverr_required, true}]}` - A challenge was solved, so
    the caller should flag the indexer. Never contains cookies.
  - `{:error, reason}` - Search execution error

  ## Examples

      iex> opts = [query: "Ubuntu", categories: [2000]]
      iex> {:ok, response} = execute_search(definition, opts)
      iex> response.status
      200

      # With FlareSolverr enabled
      iex> flaresolverr_opts = %{enabled: true, definition_id: "uuid"}
      iex> {:ok, response, markers} = execute_search(definition, opts, %{}, flaresolverr_opts)
  """
  @spec execute_search(Parsed.t(), search_opts(), map(), flaresolverr_opts()) ::
          {:ok, http_response()}
          | {:ok, http_response(), list()}
          | {:error, Error.t()}
  def execute_search(definition, opts, user_config \\ %{}, flaresolverr_opts \\ %{})

  def execute_search(%Parsed{} = definition, opts, user_config, flaresolverr_opts)
      when is_list(opts) do
    candidates = SearchRequest.candidates(definition, opts)

    case candidates do
      [] ->
        {:error, Error.search_failed("No base URL configured")}

      candidates ->
        try_candidates(
          definition,
          candidates,
          opts,
          user_config,
          flaresolverr_opts,
          nil,
          hd(candidates)
        )
    end
  end

  defp try_candidates(
         _definition,
         [],
         _opts,
         _user_config,
         _flaresolverr_opts,
         last_error,
         _first_tried
       ) do
    last_error || {:error, Error.search_failed("No base URL configured")}
  end

  defp try_candidates(
         definition,
         [candidate | rest],
         opts,
         user_config,
         flaresolverr_opts,
         _last_error,
         first_tried
       ) do
    opts_for_candidate = Keyword.put(opts, :base_url, candidate)

    with {:ok, url} <- build_search_url(definition, opts_for_candidate),
         {:ok, request_params} <- build_request_params(definition, opts_for_candidate) do
      config = Keyword.get(opts, :config, %{})

      result =
        if FlareSolverrFlow.solve_first?(flaresolverr_opts, url) do
          FlareSolverrFlow.solve_and_repeat(definition, url, request_params, user_config, config)
        else
          execute_direct_request(
            definition,
            url,
            request_params,
            user_config,
            flaresolverr_opts,
            config
          )
        end

      result = BlockPage.reject(definition, result)

      cond do
        elem(result, 0) == :ok ->
          if candidate != first_tried, do: promote(opts, candidate)
          SearchRequest.with_base_url(result, candidate)

        retryable_failure?(result) and rest != [] ->
          try_candidates(
            definition,
            rest,
            opts,
            user_config,
            flaresolverr_opts,
            result,
            first_tried
          )

        true ->
          result
      end
    end
  end

  defp promote(opts, candidate) do
    case Keyword.get(opts, :on_promote) do
      fun when is_function(fun, 1) -> fun.(candidate)
      _ -> :ok
    end
  end

  # A dead or wrong mirror answers 404 or redirects away, and neither is a
  # reason to abandon the working mirrors behind it. YTS ships six links whose
  # proxies serve HTML on / but 404 on /api/v2/list_movies.json, so the first
  # candidate the homepage probe promotes is routinely the wrong one.
  #
  # Failures that would repeat identically on every candidate stay terminal: a
  # template that will not render, or a request target the client refuses, is
  # not going to behave differently against another host. A block, parked or
  # for-sale page is the opposite: it is specific to that mirror, so move on.
  defp retryable_failure?({:error, %Error{type: :connection_failed}}), do: true

  defp retryable_failure?({:error, %Error{message: message}}) when is_binary(message) do
    String.contains?(message, "Server error: HTTP 5") or
      String.contains?(message, "HTTP 404") or
      String.contains?(message, "Blocked page:") or
      String.contains?(message, "Redirected (HTTP 3")
  end

  defp retryable_failure?(_), do: false

  # Execute request directly and detect Cloudflare challenges
  defp execute_direct_request(
         definition,
         url,
         request_params,
         user_config,
         flaresolverr_opts,
         config
       ) do
    case execute_http_request(definition, url, request_params, user_config, config) do
      {:ok, response} ->
        if cloudflare_challenge?(response) do
          handle_cloudflare_challenge(
            definition,
            url,
            request_params,
            user_config,
            flaresolverr_opts,
            config
          )
        else
          with :ok <- validate_response(response) do
            {:ok, response}
          end
        end

      {:error, _} = error ->
        error
    end
  end

  # Handle a Cloudflare challenge by earning a clearance through FlareSolverr
  # and repeating the request directly.
  defp handle_cloudflare_challenge(
         definition,
         url,
         request_params,
         user_config,
         _flaresolverr_opts,
         config
       ) do
    Logger.info("Cloudflare challenge detected for #{definition.id}, attempting FlareSolverr")

    if FlareSolverr.enabled?() do
      # A challenge despite a cached clearance means that clearance is stale
      # (expired, or bound to a user-agent that has since changed).
      ClearanceCache.delete(url)

      case FlareSolverrFlow.solve_and_repeat(definition, url, request_params, user_config, config) do
        {:ok, response} ->
          # Flag the indexer so the next search skips the doomed direct request.
          {:ok, response, [{:flaresolverr_required, true}]}

        {:error, _} = error ->
          # Already carries the readable FlareSolverr message.
          error
      end
    else
      Logger.warning("Cloudflare detected for #{definition.id} but FlareSolverr not available")

      {:error,
       Error.connection_failed(
         "Cloudflare protection detected. " <>
           "Configure FlareSolverr to access this indexer."
       )}
    end
  end

  # Detect Cloudflare challenge response
  @doc false
  def cloudflare_challenge?(%{status: 403, body: body}) when is_binary(body) do
    cloudflare_indicators = [
      "cf-browser-verification",
      "cf_clearance",
      "Cloudflare",
      "cloudflare",
      "challenge-platform",
      "jschl-answer",
      "cf-chl-bypass",
      "ddos-guard",
      "DDoS-Guard"
    ]

    Enum.any?(cloudflare_indicators, &String.contains?(body, &1)) or challenge_title?(body)
  end

  def cloudflare_challenge?(%{status: 503, body: body}) when is_binary(body) do
    String.contains?(body, "Cloudflare") || String.contains?(body, "cloudflare") ||
      challenge_title?(body)
  end

  def cloudflare_challenge?(%{body: body}) when is_binary(body), do: challenge_title?(body)

  def cloudflare_challenge?(_), do: false

  defp challenge_title?(body), do: Enum.any?(@challenge_titles, &String.contains?(body, &1))

  @doc """
  Builds the search URL from the definition's path template and search options.

  Selects the appropriate path from the definition based on categories (if specified),
  then substitutes template variables with actual values.

  ## Template Variables

  - `{{ .Keywords }}` - Main search query
  - `{{ .Query.Series }}` - TV show name (same as Keywords for now)
  - `{{ .Query.Season }}` - Season number
  - `{{ .Query.Ep }}` - Episode number
  - `{{ .Categories }}` - Comma-separated category IDs

  ## Examples

      iex> definition = %Parsed{
      ...>   links: ["https://1337x.to"],
      ...>   search: %{paths: [%{path: "/search/{{ .Keywords }}/1/"}]}
      ...> }
      iex> build_search_url(definition, query: "Ubuntu")
      {:ok, "https://1337x.to/search/Ubuntu/1/"}
  """
  @spec build_search_url(Parsed.t(), search_opts()) :: {:ok, String.t()} | {:error, Error.t()}
  def build_search_url(%Parsed{} = definition, opts) do
    with {:ok, base_url} <- get_base_url(definition, opts),
         {:ok, path_config} <- select_search_path(definition, opts),
         {:ok, path} <- render_template(path_config.path, definition, opts) do
      url = build_full_url(base_url, Links.encode_path_text(path))
      {:ok, url}
    end
  end

  @doc """
  Builds request parameters including query params, headers, and method.

  Extracts input parameters from the definition and search options,
  then constructs the final set of query parameters to send.

  ## Returns

  - `{:ok, params}` - Map with :query_params, :headers, :method, :follow_redirect
  - `{:error, reason}` - Parameter building error

  ## Examples

      iex> definition = %Parsed{search: %{inputs: %{"type" => "search"}}}
      iex> build_request_params(definition, query: "test")
      {:ok, %{query_params: %{"type" => "search"}, headers: [], method: :get, follow_redirect: nil}}
  """
  @spec build_request_params(Parsed.t(), search_opts()) ::
          {:ok, map()} | {:error, Error.t()}
  def build_request_params(%Parsed{} = definition, opts) do
    with {:ok, path} <- select_search_path(definition, opts),
         {:ok, headers} <- RequestHeaders.definition_headers(definition, opts) do
      {:ok,
       %{
         query_params: build_query_params(definition, path, opts),
         headers: headers,
         method: SearchRequest.method(path),
         follow_redirect: Map.get(path, :follow_redirect)
       }
       |> SearchRequest.put_timeout(opts)}
    end
  end

  @doc """
  Executes the HTTP request with proper timeout, headers, and rate limiting.

  Respects the definition's `request_delay` setting for rate limiting,
  handles redirects based on `follow_redirect`, and manages cookies.

  ## Parameters

  - `definition` - Parsed Cardigann definition
  - `url` - Full search URL
  - `request_params` - Request parameters from build_request_params/2
  - `user_config` - User configuration (cookies, credentials)

  Records whether the session cookies went out, via `LoggedOut.note_session_sent/1`.

  ## Examples

      iex> params = %{query_params: %{}, headers: [], method: :get}
      iex> {:ok, response} = execute_http_request(definition, url, params, %{}, %{})
      iex> response.status
      200
  """
  @spec execute_http_request(Parsed.t(), String.t(), map(), map(), map()) ::
          {:ok, http_response()} | {:error, Error.t()}
  def execute_http_request(%Parsed{} = definition, url, request_params, user_config, config) do
    throttle = fn -> apply_rate_limit(definition, request_params) end

    with {:ok, params} <- SearchRequest.throttled(request_params, throttle) do
      do_execute_http_request(definition, url, params, user_config, config)
    end
  end

  defp do_execute_http_request(definition, url, request_params, user_config, config) do
    req_opts = build_request_options(definition, url, request_params, user_config, config)

    Logger.debug("Cardigann search request: #{request_params.method} #{Helpers.redact_url(url)}")
    Logger.debug("Request params: #{inspect(request_params.query_params)}")

    case safe_request(request_params.method, url, req_opts) do
      {:ok, %Req.Response{status: status, body: body, headers: headers}} ->
        response = %{
          status: status,
          body: body,
          headers: headers
        }

        {:ok, response}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, Error.connection_failed("Request timeout")}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, Error.connection_failed("Connection failed: #{inspect(reason)}")}

      {:error, reason} ->
        {:error, Error.search_failed("Request failed: #{inspect(reason)}")}
    end
  end

  @doc """
  Runs a download-block HTTP request, resolving redirects by hand.

  The download path cannot reuse `execute_http_request/5`'s redirect handling.
  A tracker answering a download URL with `302 Location: magnet:?xt=...` is
  handing over the payload, but Req follows that redirect into
  `Finch.Request.parse_url/1`, which raises `ArgumentError` on any scheme that
  is not http(s). That exception escaped the whole Indexers boundary and
  discarded the calling Oban job, so a monitored show searched, ranked, picked
  a release, and then never grabbed it, with nothing in the log.

  Redirects are therefore followed one hop at a time with `redirect: false`.
  Each hop rebuilds its options through `build_request_options/5`, so
  `Mydia.Indexers.Cardigann.SessionCookies.pairs/4` re-checks the new URL. That
  is the per-hop origin check left out of the branch that first enabled
  redirect following: a session cookie is re-authorised for every hop instead
  of being carried across one blindly.

  A `magnet:` Location resolves without issuing a second request at all, so no
  credential is transmitted to the host that named it, regardless of
  `definition.follow_redirect`. An http(s) Location instead honours
  `follow_redirect`: when it is `false` the hop is not taken and this returns
  an error naming the status and Location, the same wording
  `validate_response/1` uses for an unfollowed redirect in the search path.
  """
  @spec execute_download_request(
          Parsed.t(),
          String.t(),
          map(),
          map(),
          map(),
          non_neg_integer()
        ) ::
          {:ok, {:magnet, String.t()}}
          | {:ok, {:response, http_response()}}
          | {:error, Error.t()}
  def execute_download_request(definition, url, request_params, user_config, config, hops \\ 5)

  def execute_download_request(_definition, url, _request_params, _user_config, _config, 0) do
    {:error, Error.search_failed("Too many redirects resolving download URL #{url}")}
  end

  def execute_download_request(definition, url, request_params, user_config, config, hops) do
    :ok = apply_rate_limit(definition, %{})

    req_opts =
      definition
      |> build_request_options(url, request_params, user_config, config)
      |> Keyword.put(:redirect, false)

    # The host only: a release link carries the passkey in its query or path.
    Logger.debug("Cardigann download request: #{request_params.method} #{URI.parse(url).host}")

    case safe_request(request_params.method, url, req_opts) do
      {:ok, %Req.Response{status: status, headers: headers}} when status in 300..399 ->
        follow_download_redirect(
          definition,
          url,
          status,
          headers,
          request_params,
          user_config,
          config,
          hops
        )

      {:ok, %Req.Response{status: status, body: body, headers: headers}} ->
        {:ok, {:response, %{status: status, body: body, headers: headers}}}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, Error.connection_failed("Request timeout")}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, Error.connection_failed("Connection failed: #{inspect(reason)}")}

      {:error, reason} ->
        {:error, Error.search_failed("Request failed: #{inspect(reason)}")}
    end
  end

  defp follow_download_redirect(
         definition,
         url,
         status,
         headers,
         request_params,
         user_config,
         config,
         hops
       ) do
    case location_header(headers) do
      nil ->
        {:error, Error.search_failed("Redirect with no Location header for #{url}")}

      "magnet:" <> _ = magnet ->
        # A magnet Location is the payload itself, handed over via a header
        # rather than a second request. Reading it issues no request and
        # leaks no credential, so this resolves regardless of
        # `follow_redirect: false`.
        Logger.info("Cardigann download URL redirected to a magnet")
        {:ok, {:magnet, magnet}}

      location when definition.follow_redirect ->
        next =
          url
          |> URI.parse()
          |> URI.merge(location)
          |> URI.to_string()

        execute_download_request(definition, next, request_params, user_config, config, hops - 1)

      location ->
        {:error,
         Error.search_failed(
           "Redirected (HTTP #{status}) to #{location} and the redirect was not followed"
         )}
    end
  end

  defp safe_request(:get, url, req_opts), do: run_req(&Req.get/2, url, req_opts)
  defp safe_request(:post, url, req_opts), do: run_req(&Req.post/2, url, req_opts)

  defp run_req(fun, url, req_opts) do
    fun.(url, req_opts)
  rescue
    exception ->
      Logger.error(
        "Cardigann HTTP request raised for #{Helpers.redact_url(url)}: #{Exception.message(exception)}"
      )

      {:error, exception}
  end

  @doc """
  Validates the HTTP response before passing to the result parser.

  Checks for common error conditions:
  - Rate limiting (429)
  - Authentication errors (401, 403)
  - Server errors (5xx)
  - Invalid response format

  ## Returns

  - `:ok` - Response is valid and ready for parsing
  - `{:error, reason}` - Response indicates an error

  ## Examples

      iex> validate_response(%{status: 200, body: "<html>...</html>"})
      :ok

      iex> validate_response(%{status: 429, body: "Rate limit exceeded"})
      {:error, %Error{type: :rate_limited}}
  """
  @spec validate_response(http_response()) :: :ok | {:error, Error.t()}

  # An unfollowed redirect used to land in the catch-all below as
  # "Unexpected status: 302", which told an operator nothing about where the
  # indexer was trying to send them. This is now only reachable when a
  # definition sets `followredirect: false`, since search follows by default.
  #
  # Task 5's retryable_failure?/1 matches on the "Redirected (HTTP " prefix.
  def validate_response(%{status: status} = response) when status in 300..399 do
    location = response |> Map.get(:headers) |> location_header()

    suffix = if location, do: " to #{location}", else: " with no Location header"

    {:error,
     Error.search_failed("Redirected (HTTP #{status})#{suffix} and the redirect was not followed")}
  end

  def validate_response(%{status: status, body: body}) do
    cond do
      status == 200 ->
        :ok

      status == 401 || status == 403 ->
        {:error, Error.connection_failed("Authentication failed")}

      status == 429 ->
        {:error, Error.rate_limited("Rate limit exceeded")}

      status >= 500 ->
        {:error, Error.search_failed("Server error: HTTP #{status}")}

      status >= 400 ->
        Logger.warning("Cardigann search returned HTTP #{status}: #{inspect(body)}")
        {:error, Error.search_failed("HTTP #{status}")}

      true ->
        Logger.warning("Unexpected HTTP status: #{status}")
        {:error, Error.search_failed("Unexpected status: #{status}")}
    end
  end

  # Private functions

  # Req 0.5 returns headers as a map of lowercase name to a list of values;
  # older shapes and hand-built test responses use a keyword-ish list.
  defp location_header(headers) when is_map(headers) do
    case Map.get(headers, "location") do
      [value | _] -> value
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp location_header(headers) when is_list(headers) do
    Enum.find_value(headers, fn
      {name, value} -> if String.downcase(to_string(name)) == "location", do: value
      _ -> nil
    end)
  end

  defp location_header(_), do: nil

  defp get_base_url(definition, opts) do
    case Keyword.get(opts, :base_url) do
      url when is_binary(url) and url != "" ->
        {:ok, String.trim_trailing(url, "/")}

      _ ->
        case Links.candidates(definition) do
          [first | _] -> {:ok, first}
          [] -> {:error, Error.search_failed("No base URL configured")}
        end
    end
  end

  @doc """
  Returns every search path a query runs, in definition order.

  Definitions paginate by listing one path per page; see
  `Mydia.Indexers.Cardigann.SearchPaths` for the category rule.
  """
  @spec matching_search_paths(Parsed.t(), search_opts()) ::
          {:ok, [map(), ...]} | {:error, Error.t()}
  def matching_search_paths(%Parsed{search: %{paths: [_ | _] = paths}} = definition, opts) do
    mappings = Map.get(definition.capabilities || %{}, :categorymappings) || []
    {:ok, SearchPaths.matching(paths, Keyword.get(opts, :categories, []), mappings)}
  end

  def matching_search_paths(%Parsed{}, _opts),
    do: {:error, Error.search_failed("No search path configured")}

  @doc """
  The search path one request uses: `opts[:search_path]` when the caller names
  one (a later page of a multi-page search), otherwise the first path
  `matching_search_paths/2` returns.
  """
  @spec select_search_path(Parsed.t(), search_opts()) :: {:ok, map()} | {:error, Error.t()}
  def select_search_path(%Parsed{} = definition, opts) do
    case Keyword.get(opts, :search_path) do
      %{} = path ->
        {:ok, path}

      _ ->
        with {:ok, [first | _]} <- matching_search_paths(definition, opts), do: {:ok, first}
    end
  end

  # Render a template string using the CardigannTemplate engine
  defp render_template(template, definition, opts) do
    with {:error, reason} <-
           CardigannTemplate.render(template, build_template_context(definition, opts),
             charset: definition.encoding
           ) do
      {:error, Error.search_failed("Search path failed to render: #{inspect(reason)}")}
    end
  end

  defp build_template_context(definition, opts),
    do: Mydia.Indexers.Cardigann.TemplateContext.build(definition, opts)

  @doc """
  Joins a rendered path onto a base URL, honouring an absolute path.

  A Cardigann definition may put a full URL in `path:` rather than a path
  relative to the site's base. Concatenating one produced
  `https://thepiratebay.org/https://apibay.org/q.php?...`, which the site
  answered with a redirect. The guard requires both a scheme and a host, so a
  relative path containing a colon still joins correctly.
  """
  @spec build_full_url(String.t(), String.t()) :: String.t()
  def build_full_url(base_url, path) do
    case URI.parse(path) do
      %URI{scheme: scheme, host: host} when is_binary(scheme) and is_binary(host) ->
        path

      _ ->
        "#{base_url}/#{String.trim_leading(path, "/")}"
    end
  end

  defp build_query_params(%Parsed{} = definition, path, opts) do
    base_params = SearchRequest.inputs(definition, path)
    allow_empty = Map.get(definition.search, :allow_empty_inputs, false) == true

    # Build template context
    context = build_template_context(definition, opts)

    # Substitute template variables in input values
    # For query params, don't URL-encode (Req will do it)
    Enum.reduce(base_params, %{}, fn {key, value}, acc ->
      case TemplateContext.render_input(value, context, definition.encoding) do
        :render_failed ->
          Logger.warning(
            "Cardigann #{definition.id}: input #{key} did not render and was omitted"
          )

          acc

        "" when not allow_empty ->
          acc

        rendered ->
          Map.put(acc, key, rendered)
      end
    end)
  end

  defp apply_rate_limit(%Parsed{request_delay: nil}, _request_params), do: :ok

  defp apply_rate_limit(%Parsed{id: definition_id, request_delay: delay}, request_params)
       when is_number(delay) do
    # Parity replay answers from a recording; there is no tracker to wait for.
    if Seam.replaying?(), do: :ok, else: throttle(definition_id, delay, request_params)
  end

  defp throttle(definition_id, delay, request_params) do
    # Convert delay to milliseconds if needed (some definitions use seconds).
    # It is a minimum interval between requests to one definition, so the first
    # request goes straight out.
    delay_ms = if delay < 10, do: trunc(delay * 1000), else: trunc(delay)
    key = "cardigann:" <> definition_id

    # A later page carries the paging time it has left; it must not queue past it.
    case Map.fetch(request_params, :receive_timeout) do
      {:ok, budget_ms} ->
        with {:error, :over_budget} <- RateLimiter.throttle(key, delay_ms, budget_ms) do
          {:error, Error.search_failed("Paging budget spent waiting for requestDelay")}
        end

      :error ->
        RateLimiter.throttle(key, delay_ms)
    end
  end

  defp build_request_options(definition, url, request_params, user_config, config) do
    {session_pairs, session_attached?} =
      SessionCookies.pairs(Map.get(user_config, :cookies), url, definition, config)

    LoggedOut.note_session_sent(session_attached?)

    {headers, clearance_attached?} =
      RequestHeaders.build(request_params.headers, url, session_pairs)

    base_opts = [
      headers: headers,
      receive_timeout: SearchRequest.receive_timeout(request_params),
      connect_options: [timeout: SearchRequest.connect_timeout(request_params)],
      # Neither a session cookie nor a clearance cookie (cf_clearance) may ride
      # a redirect to another host: Req carries a manual cookie header across
      # it (see the note on session_cookie_pairs/4). A definition cookie is a
      # credential only when built from the operator's settings.
      redirect:
        SearchRequest.follow_redirect?(definition, request_params) and not session_attached? and
          not clearance_attached? and not RequestHeaders.credential_cookie?(definition),
      retry: false
    ]

    # Cardigann selectors run against the response *text*, so a caller working
    # with raw selectors (the `download:` block) has to opt out of Req's
    # automatic JSON decoding - otherwise a JSON content-type silently turns the
    # body into a map and every selector matches nothing.
    base_opts =
      case Map.get(request_params, :decode_body) do
        false -> Keyword.put(base_opts, :decode_body, false)
        _ -> base_opts
      end

    base_opts = Seam.put_req_plug(base_opts)

    # Add query params for GET, body for POST
    case request_params.method do
      :get ->
        Keyword.put(base_opts, :params, request_params.query_params)

      :post ->
        Keyword.put(base_opts, :form, request_params.query_params)
    end
  end
end
