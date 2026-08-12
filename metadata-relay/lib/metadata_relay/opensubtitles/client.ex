defmodule MetadataRelay.OpenSubtitles.Client do
  @moduledoc """
  HTTP client for OpenSubtitles.com API v1.

  This module provides a wrapper around the OpenSubtitles API using Req.
  It handles authentication via API key and JWT tokens, and forwards requests
  to OpenSubtitles, returning the raw API responses.

  All requests require both an API key (for application identification) and
  a JWT token (for user authentication).

  ## Testing

  For testing, you can configure a custom HTTP adapter via application config,
  same as `MetadataRelay.TMDB.Client`:

      config :metadata_relay, :opensubtitles_http_adapter, fn request ->
        {request, Req.Response.new(status: 200, body: %{})}
      end

  """

  alias MetadataRelay.OpenSubtitles.Auth

  @base_url "https://api.opensubtitles.com/api/v1"

  @doc """
  Creates a new Req client configured for OpenSubtitles API requests.

  Requires OPENSUBTITLES_API_KEY environment variable and a valid JWT token
  from the Auth GenServer.

  Returns `{:ok, client}` on success or `{:error, reason}` if OpenSubtitles
  is not configured or authentication failed.
  """
  def new do
    with {:ok, api_key} <- get_api_key(),
         {:ok, token} <- Auth.get_token() do
      base_opts = [
        base_url: @base_url,
        headers: [
          {"Api-Key", api_key},
          {"Authorization", "Bearer #{token}"},
          {"Content-Type", "application/json"},
          {"User-Agent", "metadata-relay v#{MetadataRelay.version()}"}
        ]
      ]

      adapter = Application.get_env(:metadata_relay, :opensubtitles_http_adapter)
      opts = if adapter, do: Keyword.put(base_opts, :adapter, adapter), else: base_opts

      {:ok, Req.new(opts)}
    end
  end

  @doc """
  GET request to OpenSubtitles API.

  Returns `{:ok, response}` on success or `{:error, reason}` on failure.

  ## Examples

      iex> get("/subtitles", params: [imdb_id: "123456", languages: "en"])
      {:ok, %{"data" => [...]}}

  """
  def get(path, opts \\ []) do
    with {:ok, client} <- new() do
      params = Keyword.get(opts, :params, [])

      case Req.get(client, url: path, params: params) do
        {:ok, %{status: status, body: body}} when status in 200..299 ->
          {:ok, body}

        {:ok, %{status: 429, headers: headers, body: body}} ->
          # Rate limited - extract retry-after header if present
          retry_after =
            headers
            |> Enum.find(fn {k, _v} -> String.downcase(k) == "retry-after" end)
            |> case do
              {_k, v} -> v
              nil -> "60"
            end

          {:error, {:rate_limited, retry_after, body}}

        {:ok, %{status: 401, body: body}} ->
          {:error, {:authentication_failed, body}}

        {:ok, %{status: status, body: body}} ->
          {:error, {:http_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  POST request to OpenSubtitles API.

  Returns `{:ok, response}` on success or `{:error, reason}` on failure.

  ## Examples

      iex> post("/download", %{file_id: 123456})
      {:ok, %{"link" => "https://...", "file_name" => "..."}}

  """
  def post(path, body, opts \\ []) do
    with {:ok, client} <- new() do
      case Req.post(client, [url: path, json: body] ++ opts) do
        {:ok, %{status: status, body: response_body}} when status in 200..299 ->
          {:ok, response_body}

        {:ok, %{status: 429, headers: headers, body: response_body}} ->
          # Rate limited - extract retry-after header if present
          retry_after =
            headers
            |> Enum.find(fn {k, _v} -> String.downcase(k) == "retry-after" end)
            |> case do
              {_k, v} -> v
              nil -> "60"
            end

          {:error, {:rate_limited, retry_after, response_body}}

        {:ok, %{status: 401, body: response_body}} ->
          {:error, {:authentication_failed, response_body}}

        {:ok, %{status: status, body: response_body}} ->
          {:error, {:http_error, status, response_body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp get_api_key do
    case System.get_env("OPENSUBTITLES_API_KEY") do
      nil ->
        {:error, :not_configured}

      key ->
        {:ok, key}
    end
  end
end
