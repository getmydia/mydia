defmodule MetadataRelay.SubDL.Client do
  @moduledoc """
  HTTP client for SubDL.

  Two hosts are involved and only one of them is authenticated. `api.subdl.com`
  wants the API key on every search. `dl.subdl.com` serves archives with no
  credentials at all, which is the property that makes SubDL workable behind a
  shared relay: the key never leaves this service, and downloads do not draw
  against the daily search allowance.

  ## Testing

  Configure a Req adapter to intercept requests, as the other relay clients do:

      config :metadata_relay, :subdl_http_adapter, fn request ->
        {request, Req.Response.new(status: 200, body: %{})}
      end
  """

  @api_base_url "https://api.subdl.com"
  @download_base_url "https://dl.subdl.com"

  @doc """
  Searches SubDL. `params` is a keyword list of query parameters; the API key is
  added here so no caller has to hold it.
  """
  @spec search(keyword()) :: {:ok, map()} | {:error, term()}
  def search(params) do
    with {:ok, api_key} <- api_key() do
      @api_base_url
      |> client()
      |> Req.get(url: "/api/v1/subtitles", params: [{:api_key, api_key} | params])
      |> handle_response()
    end
  end

  @doc """
  Whether a SubDL API key is configured.

  Searches need the key, so without one the relay serves no subtitles at all.
  Reported at boot and over `/health` so a relay in that state is visible from
  outside rather than only when a search fails.
  """
  @spec configured?() :: boolean()
  def configured?, do: match?({:ok, _key}, api_key())

  @doc """
  Fetches a subtitle archive. `path` must already have been validated by
  `MetadataRelay.SubDL.FileId.decode/1`.
  """
  @spec fetch_archive(String.t()) :: {:ok, binary()} | {:error, term()}
  def fetch_archive(path) do
    @download_base_url
    |> client()
    |> Req.get(url: path, decode_body: false)
    |> handle_response()
  end

  defp client(base_url) do
    base_opts = [
      base_url: base_url,
      headers: [{"User-Agent", "metadata-relay v#{MetadataRelay.version()}"}],
      # Unlike the sibling clients: Req's default retry sleeps for the
      # upstream's retry-after inside this request, which blocks the Plug
      # process serving a client and hammers an endpoint already rate-limiting
      # the one shared key.
      retry: false
    ]

    adapter = Application.get_env(:metadata_relay, :subdl_http_adapter)
    Req.new(if adapter, do: Keyword.put(base_opts, :adapter, adapter), else: base_opts)
  end

  defp handle_response({:ok, %{status: status, body: body}}) when status in 200..299,
    do: {:ok, body}

  defp handle_response({:ok, %{status: 429, headers: headers, body: _body}}),
    do: {:error, {:rate_limited, retry_after(headers)}}

  defp handle_response({:ok, %{status: status, body: body}}),
    do: {:error, {:http_error, status, body}}

  defp handle_response({:error, reason}), do: {:error, reason}

  defp retry_after(headers) do
    case Enum.find(headers, fn {k, _v} -> String.downcase(k) == "retry-after" end) do
      {_k, [value | _]} -> value
      {_k, value} when is_binary(value) -> value
      _ -> "60"
    end
  end

  # A blank value is treated as absent, whitespace included. A blank env var is
  # a common deployment accident, and failing as "not configured" is clearer
  # than sending an empty key and getting an opaque rejection back from SubDL.
  defp api_key do
    case System.get_env("SUBDL_API_KEY") do
      nil ->
        {:error, :not_configured}

      key ->
        if String.trim(key) == "", do: {:error, :not_configured}, else: {:ok, key}
    end
  end
end
