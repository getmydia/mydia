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

  alias Mydia.Indexers.Cardigann.CredentialScope
  alias Mydia.Indexers.Cardigann.Links
  alias Mydia.Indexers.CardigannDefinition.Parsed
  alias Mydia.Indexers.CardigannTemplate
  alias Mydia.Indexers.Adapter.Error
  alias Mydia.Indexers.FlareSolverr
  alias Mydia.Indexers.FlareSolverr.ClearanceCache
  alias Mydia.Indexers.FlareSolverr.Response, as: FlareSolverrResponse

  require Logger

  @max_search_candidates 3

  # Req's own "req/x.y" user-agent is refused or served a different page by
  # some public trackers. Prowlarr sends a desktop browser's string by default,
  # and a definition's own user-agent header still takes precedence.
  @default_user_agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " <>
                        "(KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"

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
          config: map() | nil,
          settings: [map()] | nil
        ]

  @type http_response :: %{
          status: integer(),
          body: String.t(),
          headers: [{String.t(), String.t()}]
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
    candidates =
      case Keyword.get(opts, :base_url) do
        nil ->
          Links.candidates(definition)

        active ->
          [String.trim_trailing(active, "/") | Links.candidates(definition)] |> Enum.uniq()
      end
      |> Enum.take(@max_search_candidates)

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
        if solve_first?(flaresolverr_opts, url) do
          solve_and_repeat(definition, url, request_params, user_config, config)
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

      cond do
        elem(result, 0) == :ok ->
          if candidate != first_tried, do: promote(opts, candidate)
          result

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
  # not going to behave differently against another host.
  defp retryable_failure?({:error, %Error{type: :connection_failed}}), do: true

  defp retryable_failure?({:error, %Error{message: message}}) when is_binary(message) do
    String.contains?(message, "Server error: HTTP 5") or
      String.contains?(message, "HTTP 404") or
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

      case solve_and_repeat(definition, url, request_params, user_config, config) do
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

  # An indexer already known to sit behind Cloudflare skips the doomed direct
  # request, unless a clearance for this host is cached, in which case the
  # direct request is exactly what the clearance is for.
  defp solve_first?(flaresolverr_opts, url) do
    flaresolverr_opts[:enabled] == true and FlareSolverr.enabled?() and
      ClearanceCache.lookup(url) == :none
  end

  # Prowlarr's model (IndexerProxies/FlareSolverr/FlareSolverr.cs): FlareSolverr
  # gets the bare request, never cookies, and is used to earn a clearance, not
  # to fetch the page. The request is then repeated directly with the
  # clearance and that response is parsed, so the definition's own headers
  # (EZTV's layout cookie, a user-agent) apply exactly as on any direct
  # request. Parsing Chrome's rendered DOM instead dropped those headers and
  # returned zero rows for 1337x, EZTV and kickass while Prowlarr returned
  # plenty. The rendered DOM is kept only as a fallback for a site whose
  # clearance does not carry over to a plain HTTP client.
  #
  # No explicit rate limit here: execute_http_request/5 applies the definition's
  # request_delay before the repeat, and the direct attempt that preceded a
  # solve applied it before the challenge, so the site is not paced three times.
  defp solve_and_repeat(definition, url, request_params, user_config, config) do
    case solve(url, request_params) do
      {:ok, %FlareSolverrResponse{} = solved} ->
        ClearanceCache.put(
          url,
          FlareSolverrResponse.cookies(solved),
          FlareSolverrResponse.user_agent(solved)
        )

        repeat_after_solve(definition, url, request_params, user_config, config, solved)

      {:error, reason} ->
        {:error, flaresolverr_error(definition.id, reason)}
    end
  end

  defp repeat_after_solve(definition, url, request_params, user_config, config, solved) do
    case execute_http_request(definition, url, request_params, user_config, config) do
      {:ok, response} ->
        if cloudflare_challenge?(response) do
          Logger.info(
            "Cardigann: #{definition.id} still challenged after FlareSolverr; " <>
              "using the rendered page"
          )

          # The clearance did not carry over, so caching it only makes every
          # later search pay a doomed direct request first.
          ClearanceCache.delete(url)

          rendered = %{
            status: FlareSolverrResponse.http_status(solved) || 200,
            body: FlareSolverrResponse.body(solved) || "",
            headers: convert_flaresolverr_headers(solved)
          }

          with :ok <- validate_response(rendered), do: {:ok, rendered}
        else
          with :ok <- validate_response(response), do: {:ok, response}
        end

      {:error, _} = error ->
        error
    end
  end

  defp solve(url, %{method: :get, query_params: params}),
    do: FlareSolverr.get(append_query_params(url, params))

  defp solve(url, %{method: :post, query_params: params}),
    do: FlareSolverr.post(url, post_data: URI.encode_query(params))

  # Operator-facing text for a FlareSolverr failure. Every message starts with
  # "FlareSolverr:" so the connection test can recognise it, and none of them
  # inspects the raw reason, which used to put FlareSolverr's whole JSON body
  # and Chrome's stack trace in the admin UI.
  defp flaresolverr_error(definition_id, reason) do
    Logger.error("FlareSolverr failed for #{definition_id}: #{inspect(reason)}")

    case reason do
      {:browser_crashed, _} ->
        Error.connection_failed(
          "FlareSolverr: browser tab crashed (FlareSolverr's Chrome ran out of resources; " <>
            "lower flaresolverr.max_concurrent_requests or give FlareSolverr more memory)"
        )

      {:cookie_rejected, message} ->
        Error.connection_failed("FlareSolverr: Chrome rejected a cookie (#{message})")

      {:challenge_timeout, _} ->
        Error.connection_failed("FlareSolverr: timed out solving the challenge")

      {category, message} when is_atom(category) and is_binary(message) ->
        Error.connection_failed("FlareSolverr: #{message}")

      :timeout ->
        Error.connection_failed("FlareSolverr: request timed out")

      :flaresolverr_busy ->
        Error.connection_failed(
          "FlareSolverr: busy with other indexers; no slot freed up before the search deadline"
        )

      {:connection_error, conn_reason} ->
        Error.connection_failed("FlareSolverr: unreachable (#{inspect(conn_reason)})")

      {:http_error, status, _body} ->
        Error.connection_failed("FlareSolverr: HTTP #{status}")

      other ->
        Error.search_failed("FlareSolverr: #{inspect(other)}")
    end
  end

  # Append query params to URL
  defp append_query_params(url, params) when params == %{}, do: url

  defp append_query_params(url, params) do
    query_string =
      params
      |> Enum.map_join("&", fn {k, v} ->
        "#{URI.encode_www_form(to_string(k))}=#{URI.encode_www_form(to_string(v))}"
      end)

    if String.contains?(url, "?") do
      "#{url}&#{query_string}"
    else
      "#{url}?#{query_string}"
    end
  end

  # Convert FlareSolverr headers to list format
  defp convert_flaresolverr_headers(%FlareSolverrResponse{solution: %{headers: headers}})
       when is_map(headers) do
    Enum.map(headers, fn {k, v} -> {k, v} end)
  end

  defp convert_flaresolverr_headers(_), do: []

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
      url = build_full_url(base_url, path)
      {:ok, url}
    end
  end

  @doc """
  Builds request parameters including query params, headers, and method.

  Extracts input parameters from the definition and search options,
  then constructs the final set of query parameters to send.

  ## Returns

  - `{:ok, params}` - Map with :query_params, :headers, :method
  - `{:error, reason}` - Parameter building error

  ## Examples

      iex> definition = %Parsed{search: %{inputs: %{"type" => "search"}}}
      iex> build_request_params(definition, query: "test")
      {:ok, %{query_params: %{"type" => "search"}, headers: [], method: :get}}
  """
  @spec build_request_params(Parsed.t(), search_opts()) ::
          {:ok, map()} | {:error, Error.t()}
  def build_request_params(%Parsed{} = definition, opts) do
    query_params = build_query_params(definition, opts)
    headers = build_headers(definition)
    method = get_http_method(definition, opts)

    params = %{
      query_params: query_params,
      headers: headers,
      method: method
    }

    {:ok, params}
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

  ## Returns

  - `{:ok, response}` - HTTP response with status, body, headers
  - `{:error, reason}` - Request execution error

  ## Examples

      iex> params = %{query_params: %{}, headers: [], method: :get}
      iex> {:ok, response} = execute_http_request(definition, url, params, %{}, %{})
      iex> response.status
      200
  """
  @spec execute_http_request(Parsed.t(), String.t(), map(), map(), map()) ::
          {:ok, http_response()} | {:error, Error.t()}
  def execute_http_request(%Parsed{} = definition, url, request_params, user_config, config) do
    # Apply rate limiting if configured
    apply_rate_limit(definition)

    # Build request options
    req_opts = build_request_options(definition, url, request_params, user_config, config)

    Logger.debug("Cardigann search request: #{request_params.method} #{url}")
    Logger.debug("Request params: #{inspect(request_params.query_params)}")

    # Execute request based on method
    result = safe_request(request_params.method, url, req_opts)

    case result do
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
  `session_cookie_pairs/4` re-runs `cookie_disposition/2` against the new URL. That
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
    apply_rate_limit(definition)

    req_opts =
      definition
      |> build_request_options(url, request_params, user_config, config)
      |> Keyword.put(:redirect, false)

    Logger.debug("Cardigann download request: #{request_params.method} #{url}")

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
      Logger.error("Cardigann HTTP request raised for #{url}: #{Exception.message(exception)}")
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
  Selects the search path config for the given search options.

  Matches category-specific paths when categories are provided, otherwise
  returns the first configured path.
  """
  @spec select_search_path(Parsed.t(), search_opts()) :: {:ok, map()} | {:error, Error.t()}
  def select_search_path(%Parsed{search: %{paths: paths}}, opts) do
    categories = Keyword.get(opts, :categories, [])

    # Find the first path that matches the categories, or use the first path
    selected_path =
      if categories != [] do
        # Find a path that matches the categories, or default to first path
        Enum.find(paths, fn path ->
          path_categories = Map.get(path, :categories, [])
          # Match if path has matching categories
          path_categories != [] && Enum.any?(categories, &(&1 in path_categories))
        end) || List.first(paths)
      else
        List.first(paths)
      end

    case selected_path do
      nil -> {:error, Error.search_failed("No search path configured")}
      path -> {:ok, path}
    end
  end

  def select_search_path(%Parsed{}, _opts) do
    {:error, Error.search_failed("No search path configured")}
  end

  # Render a template string using the CardigannTemplate engine
  defp render_template(template, definition, opts) do
    context = build_template_context(definition, opts)
    CardigannTemplate.render(template, context)
  end

  # Build template context from definition and search options
  defp build_template_context(definition, opts) do
    Mydia.Indexers.Cardigann.TemplateContext.build(definition, opts)
  end

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

  defp build_query_params(%Parsed{} = definition, opts) do
    # Start with inputs from the definition
    base_params = Map.get(definition.search, :inputs, %{})
    allow_empty = Map.get(definition.search, :allow_empty_inputs, false) == true

    # Build template context
    context = build_template_context(definition, opts)

    # Substitute template variables in input values
    # For query params, don't URL-encode (Req will do it)
    Enum.reduce(base_params, %{}, fn {key, value}, acc ->
      substituted_value =
        case value do
          v when is_binary(v) ->
            # Handle special $raw: prefix (same behavior, just explicit)
            if String.starts_with?(v, "$raw:") do
              template = String.replace_prefix(v, "$raw:", "")

              case CardigannTemplate.render(template, context, url_encode: false) do
                {:ok, rendered} -> rendered
                {:error, _} -> v
              end
            else
              case CardigannTemplate.render(v, context, url_encode: false) do
                {:ok, rendered} -> rendered
                {:error, _} -> v
              end
            end

          v ->
            v
        end

      if substituted_value == "" and not allow_empty do
        acc
      else
        Map.put(acc, key, substituted_value)
      end
    end)
  end

  defp build_headers(%Parsed{search: search}) do
    case Map.get(search, :headers) do
      nil -> []
      headers when is_map(headers) -> Map.to_list(headers)
      headers when is_list(headers) -> headers
    end
  end

  defp get_http_method(%Parsed{search: %{paths: paths}}, opts) do
    categories = Keyword.get(opts, :categories, [])

    # Find the selected path's method
    selected_path =
      if categories != [] do
        Enum.find(paths, List.first(paths), fn path ->
          path_categories = Map.get(path, :categories, [])
          path_categories == [] || Enum.any?(categories, &(&1 in path_categories))
        end)
      else
        List.first(paths)
      end

    method_str = Map.get(selected_path || %{}, :method, "get")

    case String.downcase(method_str) do
      "post" -> :post
      _ -> :get
    end
  end

  defp apply_rate_limit(%Parsed{request_delay: nil}), do: :ok

  defp apply_rate_limit(%Parsed{request_delay: delay}) when is_number(delay) do
    # Convert delay to milliseconds if needed (some definitions use seconds)
    delay_ms = if delay < 10, do: trunc(delay * 1000), else: trunc(delay)
    Process.sleep(delay_ms)
    :ok
  end

  defp build_request_options(definition, url, request_params, user_config, config) do
    clearance =
      case ClearanceCache.lookup(url) do
        {:ok, clearance} -> clearance
        :none -> nil
      end

    {defined_ua, defined_cookie, other_headers} = split_headers(request_params.headers)

    # A solved clearance is bound to the user-agent that solved it, so it wins.
    user_agent = (clearance && clearance.user_agent) || defined_ua || @default_user_agent

    {session_pairs, session_attached?} =
      session_cookie_pairs(Map.get(user_config, :cookies), url, definition, config)

    clearance_pairs =
      if clearance, do: Enum.map(clearance.cookies, fn {n, v} -> "#{n}=#{v}" end), else: []

    # One cookie header only: a second one beside the definition's own is
    # dropped or mangled by some servers.
    cookie_header =
      [defined_cookie | session_pairs ++ clearance_pairs]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("; ")

    headers =
      [{"user-agent", user_agent} | other_headers] ++
        if(cookie_header == "", do: [], else: [{"cookie", cookie_header}])

    base_opts = [
      headers: headers,
      receive_timeout: 30_000,
      connect_options: [timeout: 10_000],
      # A session cookie must not ride a redirect to another host (see the
      # note on session_cookie_pairs/4). Clearance and definition cookies are
      # not credentials, so they alone do not disable redirects.
      redirect: definition.follow_redirect == true and not session_attached?,
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

    # Add query params for GET, body for POST
    case request_params.method do
      :get ->
        Keyword.put(base_opts, :params, request_params.query_params)

      :post ->
        Keyword.put(base_opts, :form, request_params.query_params)
    end
  end

  defp split_headers(headers) do
    Enum.reduce(headers || [], {nil, nil, []}, fn {name, value}, {ua, cookie, rest} ->
      value = if is_list(value), do: Enum.join(value, "; "), else: to_string(value)

      case String.downcase(to_string(name)) do
        "user-agent" -> {value, cookie, rest}
        "cookie" -> {ua, value, rest}
        _ -> {ua, cookie, rest ++ [{name, value}]}
      end
    end)
  end

  # A session cookie is a bearer credential for the tracker account. Base URL
  # candidates come straight from the definition's `links`, and a few of them are
  # cleartext (torrentlt ships `http://www.torrent.ai/`), so the header is
  # withheld rather than handed to anyone on the path. The request still goes
  # out: an anonymous result is a better outcome than a leaked login, and the
  # search reports whatever the tracker returns for a logged-out visitor.
  #
  # A cookie-bearing request also stops following redirects, because Req carries
  # a manually supplied Cookie header along a redirect even to a different host
  # (checked against the pinned Req, not assumed). Following one would hand the
  # session to whatever host the Location names, which is a leak an attacker can
  # trigger from a hijacked mirror rather than an accident. Unfollowed 3xx keeps
  # the honest handling this branch already added: validate_response/1 names the
  # Location, and failover moves on to the next candidate. Redirect following is
  # unaffected for every request without cookies.
  #
  # A session cookie is scoped to the origins the definition names as its own:
  # its links, plus any absolute search or login path it renders. A mirror
  # failover onto a stale legacylinks domain, or a download link parsed out
  # of a result row, can both name an origin the operator never trusted, and a
  # download link is remote content rather than shipped YAML. Withhold and
  # continue, because an anonymous result beats a leaked login.
  defp session_cookie_pairs(cookies, url, definition, config)
       when is_list(cookies) and cookies != [] do
    case cookie_disposition(url, CredentialScope.trusted_origins(definition, config)) do
      {:withhold, reason} ->
        Logger.warning("Cardigann: withholding session cookies from #{reason}")
        {[], false}

      :ok ->
        pairs = cookies |> Enum.map(&normalize_cookie/1) |> Enum.reject(&is_nil/1)
        {pairs, pairs != []}
    end
  end

  defp session_cookie_pairs(_cookies, _url, _definition, _config), do: {[], false}

  # The one place that decides whether a URL may receive the definition's
  # session. FlareSolverr no longer receives session cookies at all, so
  # session_cookie_pairs/4 is the only caller.
  defp cookie_disposition(url, trusted_origins) do
    cond do
      CredentialScope.cleartext?(url) ->
        {:withhold,
         "cleartext URL #{inspect(url)}. Configure an https base URL for this indexer to " <>
           "send credentials."}

      not CredentialScope.allows?(trusted_origins, url) ->
        {:withhold,
         "#{inspect(url)}, which is not one of this definition's own hosts. Searching " <>
           "anonymously."}

      true ->
        :ok
    end
  end

  # A stored session row holds either plain "name=value" strings or cookie maps
  # (older versions wrote FlareSolverr's cookies there), and
  # CardigannAuth.get_stored_session/1 hands back whatever is in the row without
  # looking. Joining a map raises Protocol.UndefinedError before the request is
  # even sent, so a leftover row would crash the next search. Entries are
  # normalized here and anything unusable is dropped.
  defp normalize_cookie(cookie) when is_binary(cookie), do: cookie

  defp normalize_cookie(cookie) when is_map(cookie) do
    name = cookie["name"] || Map.get(cookie, :name)
    value = cookie["value"] || Map.get(cookie, :value)

    # Both halves have to be strings. These rows are decoded JSON, so a nested
    # object or array can land in either field, and interpolating one raises the
    # same Protocol.UndefinedError this function exists to prevent.
    if is_binary(name) and is_binary(value), do: name <> "=" <> value, else: nil
  end

  defp normalize_cookie(_cookie), do: nil
end
