defmodule Mydia.Subtitles.Provider.OpenSubtitles do
  @moduledoc """
  Subtitle provider talking to api.opensubtitles.com directly with a user's own
  account.

  Exists so a user is not stuck behind the relay's shared quota. Requires an API
  key plus username and password.
  """

  @behaviour Mydia.Subtitles.Provider

  require Logger

  alias Mydia.Subtitles.Provider.QuotaInfo
  alias Mydia.Subtitles.Provider.SearchResult

  @default_base_url "https://api.opensubtitles.com"
  @user_agent "Mydia"
  @timeout 30_000

  @impl true
  def search(provider, params) do
    with {:ok, token} <- login(provider) do
      query = build_query(params)

      case request(provider, token, :get, "/api/v1/subtitles", params: query) do
        {:ok, %{"data" => data}} when is_list(data) ->
          {:ok, data |> Enum.flat_map(&flatten_entry/1) |> Enum.map(&SearchResult.from_map/1)}

        {:ok, _unexpected} ->
          {:error, :invalid_search_response}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  # OpenSubtitles answers with a temporary link, but the behaviour's contract is
  # subtitle content, which `Provider.Relay` also honours. Returning the link
  # would type-check and pass the downloader's is_binary guard, then land a URL
  # string on disk named like a subtitle.
  def download(provider, %{file_id: file_id}) do
    with {:ok, token} <- login(provider) do
      case request(provider, token, :post, "/api/v1/download", json: %{file_id: file_id}) do
        {:ok, %{"link" => link}} -> fetch_subtitle_body(link)
        {:ok, _unexpected} -> {:error, :invalid_download_response}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def validate_config(%{api_key: key, username: user, password: pass} = config)
      when is_binary(key) and key != "" and is_binary(user) and user != "" and
             is_binary(pass) and pass != "" do
    {:ok, config}
  end

  def validate_config(_config),
    do: {:error, "OpenSubtitles requires an API key, a username and a password"}

  @impl true
  def quota_info(provider) do
    with {:ok, token} <- login(provider),
         {:ok, %{"data" => data}} <- request(provider, token, :get, "/api/v1/infos/user") do
      used = data["downloads_count"] || 0
      total = data["allowed_downloads"] || 0

      {:ok,
       %QuotaInfo{
         type: :limited,
         provider_type: :opensubtitles,
         remaining: max(total - used, 0),
         total: total,
         reset_at: nil,
         vip: data["vip"] || false
       }}
    end
  end

  @impl true
  def capabilities do
    %{
      media_types: [:movie, :episode],
      search_keys: [:file_hash, :imdb_id, :tmdb_id, :query],
      requires_credentials: true,
      quota: :limited
    }
  end

  ## Private

  defp base_url(provider), do: Map.get(provider, :base_url) || @default_base_url

  # The download link is a plain file on a CDN, so it takes no auth headers and
  # must not be JSON-decoded.
  defp fetch_subtitle_body(url) do
    case Req.get(url, decode_body: false, receive_timeout: @timeout) do
      {:ok, %{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp login(provider) do
    body = %{username: provider.username, password: provider.password}

    case Req.post(base_url(provider) <> "/api/v1/login",
           json: body,
           headers: headers(provider),
           receive_timeout: @timeout
         ) do
      {:ok, %{status: 200, body: %{"token" => token}}} -> {:ok, token}
      {:ok, %{status: 401}} -> {:error, :invalid_credentials}
      {:ok, %{status: status}} -> {:error, {:login_failed, status}}
      {:error, reason} -> {:error, {:transport, reason}}
    end
  end

  defp request(provider, token, method, path, opts \\ []) do
    opts =
      opts
      |> Keyword.put(:headers, [{"authorization", "Bearer " <> token} | headers(provider)])
      |> Keyword.put(:receive_timeout, @timeout)
      |> Keyword.put(:url, base_url(provider) <> path)
      |> Keyword.put(:method, method)

    case Req.request(opts) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: 406}} -> {:error, :quota_exceeded}
      {:ok, %{status: 429}} -> {:error, :rate_limited}
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, {:transport, reason}}
    end
  end

  defp headers(provider) do
    [
      {"api-key", provider.api_key},
      {"user-agent", @user_agent},
      {"accept", "application/json"}
    ]
  end

  defp build_query(params) do
    params
    |> Map.take([:languages, :imdb_id, :tmdb_id, :season_number, :episode_number, :query])
    |> Map.new(fn
      {:languages, v} -> {"languages", v}
      {:imdb_id, v} -> {"imdb_id", v}
      {:tmdb_id, v} -> {"tmdb_id", v}
      {:season_number, v} -> {"season_number", v}
      {:episode_number, v} -> {"episode_number", v}
      {:query, v} -> {"query", v}
    end)
    |> then(fn q ->
      case params do
        %{file_hash: hash} when is_binary(hash) -> Map.put(q, "moviehash", hash)
        _ -> q
      end
    end)
  end

  # OpenSubtitles nests the downloadable file inside each entry's attributes.
  defp flatten_entry(%{"attributes" => attrs}) do
    case attrs["files"] do
      [%{"file_id" => file_id} = file | _rest] ->
        [
          %{
            "file_id" => file_id,
            "file_name" => file["file_name"],
            "language" => attrs["language"],
            "rating" => attrs["ratings"],
            "download_count" => attrs["download_count"],
            "hearing_impaired" => attrs["hearing_impaired"],
            "moviehash_match" => attrs["moviehash_match"]
          }
        ]

      _ ->
        []
    end
  end

  defp flatten_entry(_entry), do: []
end
