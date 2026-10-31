defmodule Mydia.Indexers.FlareSolverr do
  @moduledoc """
  Client for communicating with FlareSolverr API.

  FlareSolverr is a proxy server to bypass Cloudflare and DDoS-GUARD protection.
  It uses a headless browser to solve JavaScript challenges and returns cookies
  that can be reused for subsequent requests.

  ## Configuration

  FlareSolverr settings flow through Mydia's layered config (env > DB/UI > YAML >
  defaults), read here via `Mydia.Settings.get_runtime_config/0`. Configure it in
  any of these layers:

    * Environment: `FLARESOLVERR_ENABLED`, `FLARESOLVERR_URL`,
      `FLARESOLVERR_TIMEOUT`, `FLARESOLVERR_MAX_TIMEOUT`,
      `FLARESOLVERR_MAX_CONCURRENT_REQUESTS` (highest priority)
    * Admin UI / database: the FlareSolverr row on the Indexers tab persists
      `flaresolverr.*` `ConfigSetting` rows, then calls
      `Mydia.Config.Loader.reload/0` so the change takes effect without a restart
    * `config/config.yml` under the `flaresolverr` key

  ## Concurrency

  `max_concurrent_requests` caps the Chrome tabs FlareSolverr runs at once across
  all indexers. Each one costs a few hundred MB; the default of 1 is what keeps a
  small container from crashing tabs when several protected indexers search
  together.

  ## Usage

      # Check if FlareSolverr is available
      if Mydia.Indexers.FlareSolverr.available?() do
        case Mydia.Indexers.FlareSolverr.get("https://protected-site.com") do
          {:ok, response} ->
            # Use response.solution.response (HTML body)
            # Use response.solution.cookies for subsequent requests
          {:error, reason} ->
            # Handle error
        end
      end

  ## FlareSolverr API

  FlareSolverr exposes a REST API at `/v1` that accepts POST requests with JSON body.
  Supported commands:
  - `request.get` - Fetch a URL and solve any challenges
  - `request.post` - POST to a URL and solve any challenges
  - `sessions.create` - Create a persistent browser session
  - `sessions.list` - List active sessions
  - `sessions.destroy` - Destroy a session
  """

  alias Mydia.Downloads.Client.Helpers
  alias Mydia.Indexers.FlareSolverr.Gate
  alias Mydia.Indexers.FlareSolverr.Response

  require Logger

  @api_path "/v1"
  @receive_margin_ms 10_000

  @doc """
  Fetches a URL through FlareSolverr, solving any Cloudflare challenges.

  ## Options

    * `:timeout` - Request timeout in milliseconds (default: from config)
    * `:max_timeout` - Maximum timeout for challenging sites (default: from config)
    * `:session` - Optional session ID to reuse browser instance
    * `:cookies` - Optional list of cookies to include in the request
    * `:proxy` - Optional proxy URL to use
    * `:queue_timeout` - How long to wait for a free request slot before
      returning `{:error, :flaresolverr_busy}` (default: the configured
      `max_timeout`, the longest one solve can hold a slot, so a queued caller
      outlasts the solves ahead of it; a caller under its own deadline is
      cancelled by that deadline and the gate cleans up after it)
    * `:retry_delay_ms` - Pause before the single retry of a crashed tab or
      a solve that timed out inside FlareSolverr (default: `:flaresolverr_retry_delay_ms` app env, else 1000)

  Failures return `{:error, {category, message}}` where `category` is one of
  `:browser_crashed`, `:cookie_rejected`, `:challenge_timeout`,
  `:challenge_failed`, `:cloudflare_error`, `:captcha_required`,
  `:session_error` or `:unknown_error`.

  ## Examples

      iex> FlareSolverr.get("https://protected-site.com")
      {:ok, %Response{status: "ok", solution: %{...}}}

      iex> FlareSolverr.get("https://protected-site.com", timeout: 90_000)
      {:ok, %Response{status: "ok", solution: %{...}}}
  """
  @spec get(String.t(), keyword()) :: {:ok, Response.t()} | {:error, term()}
  def get(url, opts \\ []) do
    with {:ok, config} <- get_config(),
         :ok <- validate_enabled(config) do
      execute_request("request.get", url, opts, config)
    end
  end

  @doc """
  Sends a POST request through FlareSolverr.

  ## Options

  Same as `get/2`, plus:
    * `:post_data` - Form data to POST (map or URL-encoded string)

  ## Examples

      iex> FlareSolverr.post("https://protected-site.com/login", post_data: %{user: "test"})
      {:ok, %Response{status: "ok", solution: %{...}}}
  """
  @spec post(String.t(), keyword()) :: {:ok, Response.t()} | {:error, term()}
  def post(url, opts \\ []) do
    with {:ok, config} <- get_config(),
         :ok <- validate_enabled(config) do
      execute_request("request.post", url, opts, config)
    end
  end

  @doc """
  Checks if FlareSolverr is configured and enabled.

  Returns `true` if FlareSolverr is enabled and has a URL configured.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    case get_config() do
      {:ok, config} -> config.enabled && is_binary(config.url) && config.url != ""
      {:error, _} -> false
    end
  end

  @doc """
  Checks if FlareSolverr service is available and responding.

  This performs a health check request to verify the service is running.
  """
  @spec available?() :: boolean()
  def available? do
    case health_check() do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  @doc """
  Performs a health check on the saved FlareSolverr service.

  Returns `{:error, :disabled}` or `{:error, :not_configured}` without making a
  request when the saved config is switched off or has no URL. To probe a URL
  regardless of the saved config, use `health_check/1`.
  """
  @spec health_check() :: {:ok, map()} | {:error, term()}
  def health_check do
    with {:ok, config} <- get_config(),
         :ok <- validate_enabled(config) do
      health_check(config.url)
    end
  end

  @doc """
  Probes the FlareSolverr instance at `url`, whether or not FlareSolverr is
  enabled in the saved config.

  This answers "does this URL respond", which is what the admin UI's Test
  buttons need, including for values typed into the edit modal but not saved yet.

  Returns `{:error, :invalid_url}` without making a request unless `url` is an
  absolute http(s) URL with a host.
  """
  @spec health_check(String.t() | nil) :: {:ok, map()} | {:error, term()}
  def health_check(url) do
    if valid_url?(url), do: probe(url), else: {:error, :invalid_url}
  end

  @doc """
  Returns the current FlareSolverr configuration.
  """
  @spec config() :: map() | nil
  def config do
    case get_config() do
      {:ok, config} -> config
      {:error, _} -> nil
    end
  end

  @doc """
  Probes the current FlareSolverr status for UI display.

  Returns a map with:
    * `configured` - boolean, whether a URL is set
    * `status` - `:healthy`, `:unhealthy`, or `:disabled`
    * `url` - the configured URL
    * `version` / `sessions` - present when `:healthy`
    * `error` - present when `:unhealthy`
  """
  @spec status() :: map()
  def status do
    config = config()

    if config && config.enabled && is_binary(config.url) && config.url != "" do
      status_from_probe(config.url, health_check())
    else
      %{
        configured: config != nil && is_binary(config[:url]) && config[:url] != "",
        status: :disabled,
        url: config && config[:url]
      }
    end
  end

  @doc """
  Builds the `status/0` map for a probe of `url` that has already run.

  Lets a caller holding a `health_check/1` result refresh the displayed status
  without probing a second time.
  """
  @spec status_from_probe(String.t(), {:ok, map()} | {:error, term()}) :: map()
  def status_from_probe(url, {:ok, info}) do
    %{
      configured: true,
      status: :healthy,
      url: url,
      version: info[:version],
      sessions: info[:sessions] || []
    }
  end

  def status_from_probe(url, {:error, reason}) do
    %{configured: true, status: :unhealthy, url: url, error: reason}
  end

  ## Private Functions

  # FlareSolverr's API lives at /v1 under whatever base the operator gave,
  # which may carry a reverse-proxy path. Joining at the URI level keeps that
  # path, avoids "//v1" from a trailing slash, and drops a query or fragment
  # that string concatenation would put "/v1" inside of. Test and real
  # requests both go through here, so Test cannot pass on a URL search fails on.
  defp endpoint(base_url) do
    uri = URI.parse(base_url)
    path = String.trim_trailing(uri.path || "", "/") <> @api_path
    URI.to_string(%URI{uri | path: path, query: nil, fragment: nil})
  end

  defp probe(base_url) do
    url = endpoint(base_url)
    body = %{cmd: "sessions.list"}

    case Req.post(url, json: body, connect_options: [timeout: 5_000], receive_timeout: 10_000) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        {:ok,
         %{
           status: body["status"],
           version: body["version"],
           sessions: body["sessions"] || []
         }}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, {:connection_error, reason}}

      {:error, reason} ->
        {:error, {:request_error, reason}}
    end
  end

  # The admin modal feeds health_check/1 free text. Anything but an absolute
  # http(s) URL with a host is refused up front, so a typo like
  # "flaresolverr:8191" never reaches Req.
  defp valid_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _ ->
        false
    end
  end

  defp valid_url?(_url), do: false

  # Reads the merged runtime config (env > DB/UI > YAML > defaults) so that
  # FlareSolverr settings managed in the admin UI actually take effect. The
  # runtime config is refreshed by `Mydia.Config.Loader.reload/0` after a save.
  defp get_config do
    case Mydia.Settings.get_runtime_config() do
      %{flaresolverr: %{} = config} ->
        {:ok,
         %{
           enabled: Map.get(config, :enabled, false) || false,
           url: Map.get(config, :url),
           timeout: Map.get(config, :timeout) || 60_000,
           max_timeout: Map.get(config, :max_timeout) || 120_000,
           max_concurrent_requests: Map.get(config, :max_concurrent_requests) || 1
         }}

      _ ->
        {:error, :not_configured}
    end
  end

  defp validate_enabled(%{enabled: true, url: url}) when is_binary(url) and url != "" do
    :ok
  end

  defp validate_enabled(%{enabled: false}) do
    {:error, :disabled}
  end

  defp validate_enabled(_) do
    {:error, :not_configured}
  end

  defp execute_request(cmd, url, opts, config) do
    flaresolverr_url = endpoint(config.url)
    timeout = opts[:timeout] || config.timeout
    max_timeout = opts[:max_timeout] || config.max_timeout

    # FlareSolverr keeps solving for up to max_timeout and only then answers.
    # Giving up sooner would leave its tab running while the caller moves on,
    # so the transport waits out the longest solve plus a margin.
    receive_timeout = max(timeout, max_timeout + @receive_margin_ms)

    body =
      %{
        cmd: cmd,
        url: url,
        maxTimeout: max_timeout
      }
      |> maybe_add_session(opts[:session])
      |> maybe_add_cookies(opts[:cookies])
      |> maybe_add_proxy(opts[:proxy])
      |> maybe_add_post_data(opts[:post_data])

    Logger.debug("FlareSolverr request: #{cmd} #{Helpers.redact_url(url)}")

    request = fn -> post_to_flaresolverr(flaresolverr_url, body, receive_timeout, url) end

    # The retry runs inside the gate, so it keeps its slot instead of queueing
    # behind other callers while the first attempt's tab is still being torn down.
    Gate.run(
      fn -> request_with_retry(request, opts) end,
      limit: config.max_concurrent_requests,
      timeout: opts[:queue_timeout] || max_timeout
    )
  end

  # A crashed Chrome tab or a solve that ran out of time is FlareSolverr
  # running short of resources, and a second attempt usually succeeds once
  # the tab is gone. FlareSolverr reports both only after it has finished with
  # the tab. A transport timeout is deliberately not retried: the first tab may
  # still be alive, and a second one is what the gate exists to prevent.
  # Anything else (a captcha, a bad cookie) would fail the same way again.
  defp request_with_retry(request, opts) do
    case request.() do
      {:error, {category, _message}} when category in [:browser_crashed, :challenge_timeout] ->
        Process.sleep(retry_delay(opts))
        request.()

      result ->
        result
    end
  end

  defp retry_delay(opts) do
    Keyword.get(opts, :retry_delay_ms) ||
      Application.get_env(:mydia, :flaresolverr_retry_delay_ms, 1_000)
  end

  defp post_to_flaresolverr(flaresolverr_url, body, timeout, url) do
    case Req.post(flaresolverr_url, json: body, receive_timeout: timeout, retry: false) do
      {:ok, %Req.Response{status: 200, body: response_body}} when is_map(response_body) ->
        handle_response(response_body, url)

      # FlareSolverr reports a failed solve as HTTP 500 with the same
      # {"status": "error", "message": ...} body it would otherwise send with a
      # 200. Treating it as a bare HTTP error put the raw map, Chrome stack
      # trace included, in front of operators.
      {:ok, %Req.Response{status: 500, body: %{"status" => "error"} = response_body}} ->
        handle_response(response_body, url)

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("FlareSolverr HTTP error #{status}: #{inspect(body)}")
        {:error, {:http_error, status, body}}

      {:error, %Req.TransportError{reason: :timeout}} ->
        Logger.warning("FlareSolverr request timeout for #{Helpers.redact_url(url)}")
        {:error, :timeout}

      {:error, %Req.TransportError{reason: reason}} ->
        Logger.error("FlareSolverr connection error: #{inspect(reason)}")
        {:error, {:connection_error, reason}}

      {:error, reason} ->
        Logger.error("FlareSolverr request failed: #{inspect(reason)}")
        {:error, {:request_error, reason}}
    end
  end

  defp handle_response(%{"status" => "ok"} = body, url) do
    case Response.from_json(body) do
      {:ok, response} ->
        duration = Response.duration_ms(response)

        Logger.info(
          "FlareSolverr solved challenge for #{Helpers.redact_url(url)} in #{duration}ms"
        )

        {:ok, response}

      {:error, reason} ->
        {:error, {:parse_error, reason}}
    end
  end

  defp handle_response(%{"status" => "error", "message" => message}, url) do
    Logger.warning("FlareSolverr failed for #{Helpers.redact_url(url)}: #{message}")
    {:error, {categorize_error(message), summarize_message(message)}}
  end

  defp handle_response(body, url) do
    Logger.error(
      "FlareSolverr unexpected response for #{Helpers.redact_url(url)}: #{inspect(body)}"
    )

    {:error, {:unexpected_response, body}}
  end

  # Specific causes go first, because FlareSolverr wraps every failure in
  # "Error solving the challenge". A row matches when the lowercased message
  # contains every needle in it, so a rejected cookie needs both words.
  @error_categories [
    {["tab crashed"], :browser_crashed},
    {["cookie", "domain"], :cookie_rejected},
    {["timeout"], :challenge_timeout},
    {["challenge"], :challenge_failed},
    {["cloudflare"], :cloudflare_error},
    {["captcha"], :captcha_required},
    {["session"], :session_error}
  ]

  defp categorize_error(message) when is_binary(message) do
    message_lower = String.downcase(message)

    Enum.find_value(@error_categories, :unknown_error, fn {needles, category} ->
      if Enum.all?(needles, &String.contains?(message_lower, &1)), do: category
    end)
  end

  defp categorize_error(_), do: :unknown_error

  # FlareSolverr's message is "Error: Error solving the challenge. Message: <cause>"
  # followed by Chrome's session info and a stack trace. Only the cause is useful
  # to an operator.
  defp summarize_message(message) when is_binary(message) do
    message
    |> String.split("\n", parts: 2)
    |> hd()
    |> String.replace(~r/^Error: Error solving the challenge\. Message: /, "")
    |> String.trim()
  end

  defp summarize_message(message), do: inspect(message)

  defp maybe_add_session(body, nil), do: body
  defp maybe_add_session(body, session), do: Map.put(body, :session, session)

  defp maybe_add_cookies(body, nil), do: body
  defp maybe_add_cookies(body, []), do: body

  defp maybe_add_cookies(body, cookies) when is_list(cookies) do
    Map.put(body, :cookies, cookies)
  end

  defp maybe_add_proxy(body, nil), do: body
  defp maybe_add_proxy(body, proxy), do: Map.put(body, :proxy, %{url: proxy})

  defp maybe_add_post_data(body, nil), do: body
  defp maybe_add_post_data(body, post_data), do: Map.put(body, :postData, post_data)
end
