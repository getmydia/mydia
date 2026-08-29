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
     - If FlareSolverr enabled: Route through FlareSolverr
     - If Cloudflare detected: Auto-retry through FlareSolverr
  4. **Validate Response:** Check response is valid
  5. **Return Response:** Pass to result parser (handled by caller)

  ## FlareSolverr Integration

  When an indexer requires Cloudflare bypass:
  1. Check if `flaresolverr_enabled` is true for the indexer
  2. Check if global FlareSolverr is configured and available
  3. Route requests through FlareSolverr if both conditions are met
  4. Extract and cache cookies from FlareSolverr responses
  5. Reuse cached cookies for subsequent requests until they expire

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

  alias Mydia.Indexers.Cardigann.Links
  alias Mydia.Indexers.CardigannDefinition.Parsed
  alias Mydia.Indexers.CardigannTemplate
  alias Mydia.Indexers.Adapter.Error
  alias Mydia.Indexers.FlareSolverr
  alias Mydia.Indexers.FlareSolverr.Response, as: FlareSolverrResponse

  require Logger

  @max_search_candidates 3

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
    - `:definition_id` - Database ID for storing FlareSolverr cookies

  ## Returns

  - `{:ok, response}` - HTTP response ready for parsing
  - `{:ok, response, flaresolverr_cookies}` - Response with FlareSolverr cookies to cache
  - `{:error, reason}` - Search execution error

  ## Examples

      iex> opts = [query: "Ubuntu", categories: [2000]]
      iex> {:ok, response} = execute_search(definition, opts)
      iex> response.status
      200

      # With FlareSolverr enabled
      iex> flaresolverr_opts = %{enabled: true, definition_id: "uuid"}
      iex> {:ok, response, cookies} = execute_search(definition, opts, %{}, flaresolverr_opts)
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
      result =
        if should_use_flaresolverr?(flaresolverr_opts) do
          execute_with_flaresolverr(definition, url, request_params, user_config)
        else
          execute_direct_request(definition, url, request_params, user_config, flaresolverr_opts)
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
  defp execute_direct_request(definition, url, request_params, user_config, flaresolverr_opts) do
    case execute_http_request(definition, url, request_params, user_config) do
      {:ok, response} ->
        if cloudflare_challenge?(response) do
          handle_cloudflare_challenge(
            definition,
            url,
            request_params,
            user_config,
            flaresolverr_opts
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

  # Handle Cloudflare challenge by routing through FlareSolverr
  defp handle_cloudflare_challenge(
         definition,
         url,
         request_params,
         user_config,
         _flaresolverr_opts
       ) do
    Logger.info("Cloudflare challenge detected for #{definition.id}, attempting FlareSolverr")

    if FlareSolverr.enabled?() do
      case execute_with_flaresolverr(definition, url, request_params, user_config) do
        {:ok, response, cookies} ->
          # Return with indicator that FlareSolverr was used and indexer should be flagged
          {:ok, response, [{:flaresolverr_required, true} | cookies]}

        {:ok, response} ->
          {:ok, response, [{:flaresolverr_required, true}]}

        {:error, _} ->
          # FlareSolverr failed, return original Cloudflare error
          Logger.warning(
            "FlareSolverr failed for #{definition.id}, falling back to Cloudflare error"
          )

          {:error,
           Error.connection_failed(
             "Cloudflare protection detected but FlareSolverr failed. " <>
               "Enable FlareSolverr for this indexer or try again later."
           )}
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

  # Execute request through FlareSolverr
  defp execute_with_flaresolverr(definition, url, request_params, user_config) do
    Logger.debug("Executing request through FlareSolverr: #{url}")

    # Apply rate limiting if configured
    apply_rate_limit(definition)

    # Build FlareSolverr options from user_config
    flaresolverr_request_opts = build_flaresolverr_opts(user_config)

    result =
      case request_params.method do
        :get ->
          # For GET requests, append query params to URL
          url_with_params = append_query_params(url, request_params.query_params)
          FlareSolverr.get(url_with_params, flaresolverr_request_opts)

        :post ->
          FlareSolverr.post(
            url,
            Keyword.put(flaresolverr_request_opts, :post_data, request_params.query_params)
          )
      end

    case result do
      {:ok, %FlareSolverrResponse{} = fs_response} ->
        # Convert FlareSolverr response to http_response format
        response = %{
          status: FlareSolverrResponse.http_status(fs_response) || 200,
          body: FlareSolverrResponse.body(fs_response) || "",
          headers: convert_flaresolverr_headers(fs_response)
        }

        # Extract cookies for caching
        cookies = FlareSolverrResponse.cookies(fs_response)

        with :ok <- validate_response(response) do
          if cookies != [] do
            {:ok, response, cookies}
          else
            {:ok, response}
          end
        end

      {:error, {:challenge_failed, message}} ->
        Logger.error("FlareSolverr challenge failed for #{definition.id}: #{message}")
        {:error, Error.connection_failed("Cloudflare challenge failed: #{message}")}

      {:error, {:challenge_timeout, message}} ->
        Logger.error("FlareSolverr timeout for #{definition.id}: #{message}")
        {:error, Error.connection_failed("Cloudflare challenge timeout: #{message}")}

      {:error, :timeout} ->
        Logger.error("FlareSolverr request timeout for #{definition.id}")
        {:error, Error.connection_failed("FlareSolverr request timeout")}

      {:error, {:connection_error, reason}} ->
        Logger.error("FlareSolverr connection error for #{definition.id}: #{inspect(reason)}")
        {:error, Error.connection_failed("FlareSolverr unavailable: #{inspect(reason)}")}

      {:error, reason} ->
        Logger.error("FlareSolverr error for #{definition.id}: #{inspect(reason)}")
        {:error, Error.search_failed("FlareSolverr error: #{inspect(reason)}")}
    end
  end

  # Check if FlareSolverr should be used for this request
  defp should_use_flaresolverr?(flaresolverr_opts) do
    flaresolverr_opts[:enabled] == true && FlareSolverr.enabled?()
  end

  # Build FlareSolverr request options from user_config
  defp build_flaresolverr_opts(user_config) do
    opts = []

    # Add cookies if present
    case Map.get(user_config, :cookies) do
      cookies when is_list(cookies) and cookies != [] ->
        # Convert cookies to FlareSolverr format
        fs_cookies =
          Enum.map(cookies, fn
            cookie when is_binary(cookie) ->
              # Parse "name=value" format
              case String.split(cookie, "=", parts: 2) do
                [name, value] -> %{name: name, value: value}
                _ -> nil
              end

            cookie when is_map(cookie) ->
              cookie
          end)
          |> Enum.reject(&is_nil/1)

        if fs_cookies != [], do: Keyword.put(opts, :cookies, fs_cookies), else: opts

      _ ->
        opts
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
  defp cloudflare_challenge?(%{status: 403, body: body}) when is_binary(body) do
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

    Enum.any?(cloudflare_indicators, &String.contains?(body, &1))
  end

  defp cloudflare_challenge?(%{status: 503, body: body}) when is_binary(body) do
    String.contains?(body, "Cloudflare") || String.contains?(body, "cloudflare")
  end

  defp cloudflare_challenge?(_), do: false

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
      iex> {:ok, response} = execute_http_request(definition, url, params, %{})
      iex> response.status
      200
  """
  @spec execute_http_request(Parsed.t(), String.t(), map(), map()) ::
          {:ok, http_response()} | {:error, Error.t()}
  def execute_http_request(%Parsed{} = definition, url, request_params, user_config) do
    # Apply rate limiting if configured
    apply_rate_limit(definition)

    # Build request options
    req_opts = build_request_options(definition, url, request_params, user_config)

    Logger.debug("Cardigann search request: #{request_params.method} #{url}")
    Logger.debug("Request params: #{inspect(request_params.query_params)}")

    # Execute request based on method
    result =
      case request_params.method do
        :get ->
          Req.get(url, req_opts)

        :post ->
          Req.post(url, req_opts)
      end

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

  # A Cardigann definition may put a full URL in `path:` rather than a path
  # relative to the site's base. The Pirate Bay does exactly that, pointing at
  # https://apibay.org/q.php. Concatenating it onto the base URL produced
  # https://thepiratebay.org/https://apibay.org/q.php?... which the site
  # answered with a redirect, surfacing to the operator as
  # "Unexpected status: 302".
  defp build_full_url(base_url, path) do
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

  defp build_request_options(definition, url, request_params, user_config) do
    # Base options
    base_opts = [
      headers: request_params.headers,
      receive_timeout: 30_000,
      connect_options: [timeout: 10_000],
      redirect: definition.follow_redirect,
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
    opts_with_params =
      case request_params.method do
        :get ->
          Keyword.put(base_opts, :params, request_params.query_params)

        :post ->
          Keyword.put(base_opts, :form, request_params.query_params)
      end

    # Add cookies if present in user config
    case Map.get(user_config, :cookies) do
      cookies when is_list(cookies) and cookies != [] ->
        attach_cookies(opts_with_params, url, cookies)

      _ ->
        opts_with_params
    end
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
  defp attach_cookies(opts, url, cookies) do
    if cleartext_url?(url) do
      Logger.warning(
        "Cardigann: withholding session cookies from cleartext URL #{inspect(url)}. " <>
          "Configure an https base URL for this indexer to send credentials."
      )

      opts
    else
      cookie_header = Enum.join(cookies, "; ")
      existing_headers = Keyword.get(opts, :headers, [])

      opts
      |> Keyword.put(:headers, [{"Cookie", cookie_header} | existing_headers])
      |> Keyword.put(:redirect, false)
    end
  end

  # Loopback is a secure context in the same sense browsers use the term: the
  # request never reaches a network, so a local mirror or a test server is not
  # an exposure. Everything else on plain http is.
  @loopback_hosts ~w(localhost 127.0.0.1 ::1 0:0:0:0:0:0:0:1)

  defp cleartext_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "http", host: host} ->
        String.downcase(host || "") not in @loopback_hosts

      _ ->
        false
    end
  end

  defp cleartext_url?(_url), do: false
end
