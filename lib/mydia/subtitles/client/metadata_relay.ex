defmodule Mydia.Subtitles.Client.MetadataRelay do
  @moduledoc """
  HTTP client for metadata-relay subtitle API endpoints.

  Communicates with the metadata-relay service to search for and download subtitles
  when running in relay mode. The relay service abstracts the underlying subtitle
  provider (SubDL today) behind a standardized API.

  ## Features

  - Search for subtitles by IMDB ID, TMDB ID, or query text. Hash search is not
    available: the relay's provider matches on title and episode only, and a
    `file_hash` in the params is ignored rather than honoured.
  - Fetch temporary download URLs for subtitle files
  - Automatic retry with exponential backoff for transient failures
  - Rate limiting handling with Retry-After header support
  - Caching of search results to minimize API calls
  - Comprehensive error handling and logging

  ## Configuration

  The client reads configuration from the application environment:

      config :mydia, :subtitle_relay,
        base_url: "http://localhost:4001",
        timeout: 10_000

  The base URL can also be configured via the `METADATA_RELAY_URL` environment
  variable. When nothing is configured the client uses the shared default from
  `Mydia.Metadata.metadata_relay_url/0`, so the relay provider works on an
  install that sets none of this. See `base_url/0` for the full precedence.

  ## Caching

  Caching is handled by the metadata-relay service itself, so the client does not
  need to implement its own caching layer. Searches are cached for 7 days, keyed
  on the search criteria, which is what keeps the relay's single shared provider
  key viable across every install. Errors are not cached.

  ## Usage

      # Search by IMDB ID
      {:ok, results} = MetadataRelay.search(%{
        imdb_id: "816692",
        languages: "en,es"
      })

      # Get download URL
      {:ok, download_info} = MetadataRelay.get_download_url(12345)

  """

  require Logger

  @timeout 10_000
  @max_retries 3
  @initial_backoff 1_000

  @doc """
  Searches for subtitles based on the provided criteria.

  ## Parameters

  - `params` - Map with search criteria:
    - `:imdb_id` - IMDB identifier (without "tt" prefix)
    - `:tmdb_id` - TMDB identifier
    - `:languages` - Comma-separated language codes (e.g., "en,es,fr")
    - `:query` - Text search query (fallback option)
    - `:media_type` - "movie" or "episode"
    - `:season_number`, `:episode_number` - Episode coordinates

  A `:file_hash` is accepted for call-site compatibility but the relay ignores
  it; nothing behind the relay can search by hash.

  - `opts` - Keyword list of options:
    - `:timeout` - Request timeout in milliseconds (default: 10_000)

  ## Returns

  - `{:ok, %{"subtitles" => [...]}}` - List of subtitle results
  - `{:error, reason}` - Error tuple with reason

  ## Examples

      iex> search(%{imdb_id: "816692", languages: "en"})
      {:ok, %{"subtitles" => [%{"id" => 12345, "language" => "en", ...}]}}

      iex> search(%{query: "no such film", languages: "en"})
      {:ok, %{"subtitles" => []}}

  """
  @spec search(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def search(params, opts \\ []) do
    perform_search(params, opts)
  end

  @doc """
  Gets a temporary download URL for a subtitle file.

  ## Parameters

  - `file_id` - The subtitle file ID from search results
  - `opts` - Keyword list of options:
    - `:timeout` - Request timeout in milliseconds (default: 10_000)

  ## Returns

  - `{:ok, download_info}` - Map with download URL and metadata:
    - `"download_url"` - Temporary download URL
    - `"file_name"` - Original subtitle file name
    - `"requests_used"` - Number of download requests used
    - `"requests_remaining"` - Remaining download quota
  - `{:error, reason}` - Error tuple with reason

  ## Examples

      iex> get_download_url(12345)
      {:ok, %{
        "download_url" => "https://...",
        "file_name" => "subtitle.srt",
        "requests_used" => 10,
        "requests_remaining" => 90
      }}

  """
  @spec get_download_url(integer() | String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_download_url(file_id, opts \\ []) do
    base = base_url()
    timeout = Keyword.get(opts, :timeout, @timeout)

    if base == "" do
      {:error, :metadata_relay_not_configured}
    else
      url = "#{base}/api/v1/subtitles/download-url/#{file_id}"

      Logger.debug("Fetching subtitle download URL",
        file_id: file_id,
        url: url
      )

      perform_get_request(url, timeout)
    end
  end

  ## Private Functions

  defp perform_search(params, opts) do
    base = base_url()
    timeout = Keyword.get(opts, :timeout, @timeout)

    if base == "" do
      {:error, :metadata_relay_not_configured}
    else
      url = "#{base}/api/v1/subtitles/search"

      Logger.debug("Searching metadata-relay for subtitles",
        params: inspect(params),
        url: url
      )

      perform_post_request(url, params, timeout)
    end
  end

  defp perform_post_request(url, body, timeout, retry_count \\ 0) do
    headers = [
      {"content-type", "application/json"},
      {"user-agent", Mydia.Metadata.Provider.HTTP.user_agent()}
    ]

    json_body = Jason.encode!(body)

    case Req.post(url, headers: headers, body: json_body, receive_timeout: timeout) do
      {:ok, %{status: 200, body: response}} ->
        {:ok, response}

      {:ok, %{status: 429, headers: headers}} ->
        handle_rate_limit(headers, url, body, timeout, retry_count, :post)

      {:ok, %{status: 401, body: body}} ->
        Logger.error("Metadata relay authentication failed", response: body)
        {:error, :authentication_failed}

      {:ok, %{status: 503}} ->
        handle_service_unavailable(url, body, timeout, retry_count, :post)

      {:ok, %{status: status, body: body}} when status >= 500 ->
        handle_server_error(status, body, url, body, timeout, retry_count, :post)

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Metadata relay request failed",
          status: status,
          response: inspect(body)
        )

        {:error, {:http_error, status, body}}

      {:error, %{reason: :timeout}} ->
        handle_timeout(url, body, timeout, retry_count, :post)

      {:error, %{reason: reason}} ->
        handle_network_error(reason, url, body, timeout, retry_count, :post)

      {:error, reason} ->
        Logger.error("Metadata relay request failed", reason: inspect(reason))
        {:error, reason}
    end
  rescue
    error ->
      Logger.error("Metadata relay request exception",
        error: Exception.message(error),
        stacktrace: __STACKTRACE__
      )

      {:error, {:exception, error}}
  end

  defp perform_get_request(url, timeout, retry_count \\ 0) do
    headers = [{"user-agent", Mydia.Metadata.Provider.HTTP.user_agent()}]

    case Req.get(url, headers: headers, receive_timeout: timeout) do
      {:ok, %{status: 200, body: response}} ->
        {:ok, response}

      {:ok, %{status: 429, headers: headers}} ->
        handle_rate_limit(headers, url, nil, timeout, retry_count, :get)

      {:ok, %{status: 401, body: body}} ->
        Logger.error("Metadata relay authentication failed", response: body)
        {:error, :authentication_failed}

      {:ok, %{status: 404}} ->
        Logger.warning("Subtitle file not found", url: url)
        {:error, :not_found}

      {:ok, %{status: 503}} ->
        handle_service_unavailable(url, nil, timeout, retry_count, :get)

      {:ok, %{status: status, body: body}} when status >= 500 ->
        handle_server_error(status, body, url, nil, timeout, retry_count, :get)

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Metadata relay request failed",
          status: status,
          response: inspect(body)
        )

        {:error, {:http_error, status, body}}

      {:error, %{reason: :timeout}} ->
        handle_timeout(url, nil, timeout, retry_count, :get)

      {:error, %{reason: reason}} ->
        handle_network_error(reason, url, nil, timeout, retry_count, :get)

      {:error, reason} ->
        Logger.error("Metadata relay request failed", reason: inspect(reason))
        {:error, reason}
    end
  rescue
    error ->
      Logger.error("Metadata relay request exception",
        error: Exception.message(error),
        stacktrace: __STACKTRACE__
      )

      {:error, {:exception, error}}
  end

  # Rate limiting handler
  defp handle_rate_limit(headers, url, body, timeout, retry_count, method) do
    retry_after = extract_retry_after(headers)

    Logger.warning("Metadata relay rate limited",
      retry_after: retry_after,
      retry_count: retry_count
    )

    if retry_count < @max_retries and retry_after do
      # Wait for the retry-after period, then retry
      wait_time = retry_after * 1000
      Process.sleep(wait_time)

      case method do
        :post -> perform_post_request(url, body, timeout, retry_count + 1)
        :get -> perform_get_request(url, timeout, retry_count + 1)
      end
    else
      {:error, {:rate_limited, retry_after}}
    end
  end

  # Service unavailable handler (503)
  defp handle_service_unavailable(url, body, timeout, retry_count, method) do
    if retry_count < @max_retries do
      backoff = calculate_backoff(retry_count)

      Logger.warning("Metadata relay service unavailable, retrying",
        retry_count: retry_count,
        backoff_ms: backoff
      )

      Process.sleep(backoff)

      case method do
        :post -> perform_post_request(url, body, timeout, retry_count + 1)
        :get -> perform_get_request(url, timeout, retry_count + 1)
      end
    else
      Logger.error("Metadata relay service unavailable after #{@max_retries} retries")
      {:error, :service_unavailable}
    end
  end

  # Server error handler (5xx)
  defp handle_server_error(status, response, url, body, timeout, retry_count, method) do
    if retry_count < @max_retries do
      backoff = calculate_backoff(retry_count)

      Logger.warning("Metadata relay server error, retrying",
        status: status,
        retry_count: retry_count,
        backoff_ms: backoff
      )

      Process.sleep(backoff)

      case method do
        :post -> perform_post_request(url, body, timeout, retry_count + 1)
        :get -> perform_get_request(url, timeout, retry_count + 1)
      end
    else
      Logger.error("Metadata relay server error after #{@max_retries} retries",
        status: status,
        response: inspect(response)
      )

      {:error, {:http_error, status, response}}
    end
  end

  # Timeout handler
  defp handle_timeout(url, body, timeout, retry_count, method) do
    if retry_count < @max_retries do
      backoff = calculate_backoff(retry_count)

      Logger.warning("Metadata relay request timeout, retrying",
        retry_count: retry_count,
        backoff_ms: backoff
      )

      Process.sleep(backoff)

      case method do
        :post -> perform_post_request(url, body, timeout, retry_count + 1)
        :get -> perform_get_request(url, timeout, retry_count + 1)
      end
    else
      Logger.error("Metadata relay request timeout after #{@max_retries} retries")
      {:error, :timeout}
    end
  end

  # Network error handler
  defp handle_network_error(reason, url, body, timeout, retry_count, method) do
    if retry_count < @max_retries and retryable_error?(reason) do
      backoff = calculate_backoff(retry_count)

      Logger.warning("Metadata relay network error, retrying",
        reason: inspect(reason),
        retry_count: retry_count,
        backoff_ms: backoff
      )

      Process.sleep(backoff)

      case method do
        :post -> perform_post_request(url, body, timeout, retry_count + 1)
        :get -> perform_get_request(url, timeout, retry_count + 1)
      end
    else
      Logger.error("Metadata relay network error",
        reason: inspect(reason),
        retry_count: retry_count
      )

      {:error, {:network_error, reason}}
    end
  end

  # Check if an error is retryable
  defp retryable_error?(:econnrefused), do: true
  defp retryable_error?(:closed), do: true
  defp retryable_error?(:nxdomain), do: false
  defp retryable_error?(_), do: false

  # Extract Retry-After header value
  defp extract_retry_after(headers) do
    retry_header =
      Enum.find_value(headers, fn
        {"retry-after", value} -> value
        _ -> nil
      end)

    case retry_header do
      nil -> nil
      value when is_binary(value) -> parse_retry_after(value)
      value when is_integer(value) -> value
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp parse_retry_after(value) do
    case Integer.parse(value) do
      {seconds, _} -> seconds
      :error -> nil
    end
  end

  # Calculate exponential backoff
  defp calculate_backoff(retry_count) do
    (@initial_backoff * :math.pow(2, retry_count)) |> round()
  end

  @doc """
  Returns the metadata-relay base URL this client talks to.

  Subtitle-specific configuration wins, then general relay configuration, then
  the environment. When none of those are set the shared default from
  `Mydia.Metadata.metadata_relay_url/0` applies, which is what makes the relay
  provider work on an install that configures nothing.
  """
  @spec base_url() :: String.t()
  def base_url do
    # The final clause is the same resolver every other relay consumer uses, and
    # it carries the https://relay.mydia.dev default. This chain used to end in
    # "" instead, so an install that never sets METADATA_RELAY_URL -- the normal
    # self-hosted case -- failed every subtitle search with
    # :metadata_relay_not_configured while metadata lookups on that same install
    # worked, because they went through the shared resolver and got the default.
    #
    # METADATA_RELAY_URL stays listed explicitly rather than being left to the
    # final clause: it has always outranked SUBTITLE_RELAY_URL here, and folding
    # it into the fallback would silently invert that for an operator setting
    # both.
    Application.get_env(:mydia, :subtitle_relay_url) ||
      Application.get_env(:mydia, :metadata_relay_url) ||
      System.get_env("METADATA_RELAY_URL") ||
      System.get_env("SUBTITLE_RELAY_URL") ||
      Mydia.Metadata.metadata_relay_url()
  end
end
