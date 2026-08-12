defmodule Mydia.Subtitles.Provider.OpenSubtitles do
  @moduledoc """
  Subtitle provider talking to api.opensubtitles.com directly with a user's own
  account.

  Exists so a heavy user is not stuck competing for `Mydia.Subtitles.Provider.Relay`'s
  shared quota. Requires an API key (application identity) plus a username and
  password (user identity, exchanged for a short-lived JWT via `/login`).

  Request/response shapes here are verified against
  `metadata-relay/lib/metadata_relay/opensubtitles/{client,handler,auth}.ex`,
  which talks to the same live API in production, rather than assumed.
  """

  @behaviour Mydia.Subtitles.Provider

  require Logger

  alias Mydia.Subtitles.Provider.QuotaInfo
  alias Mydia.Subtitles.Provider.SearchResult

  @default_base_url "https://api.opensubtitles.com"
  @timeout 30_000

  @impl true
  def search(provider, params) do
    with {:ok, token} <- login(provider) do
      query = build_query(params)

      case request(provider, token, :get, "/api/v1/subtitles", params: query) do
        {:ok, %{"data" => data}} when is_list(data) ->
          {:ok, data |> Enum.map(&extract_result/1) |> Enum.map(&SearchResult.from_map/1)}

        {:ok, unexpected} ->
          {:error, {:invalid_search_response, unexpected}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # download/2's contract (see Mydia.Subtitles.Provider) requires the raw
  # file content, not a link. OpenSubtitles' /download endpoint only ever
  # hands back a temporary link (handler.ex's get_download_url/1), so a
  # second hop fetches the bytes -- same two-hop shape as
  # Mydia.Subtitles.Provider.Relay.download/2.
  @impl true
  def download(provider, %{file_id: file_id}) do
    with {:ok, token} <- login(provider),
         {:ok, %{"link" => link}} <-
           request(provider, token, :post, "/api/v1/download", json: %{file_id: file_id}) do
      fetch_content(link)
    else
      {:ok, unexpected} -> {:error, {:invalid_download_response, unexpected}}
      {:error, reason} -> {:error, reason}
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
         {:ok, %{"data" => data}} <- request(provider, token, :get, "/api/v1/infos/user"),
         {:ok, quota} <- extract_quota(data) do
      {:ok, quota}
    else
      {:ok, unexpected} -> {:error, {:invalid_quota_response, unexpected}}
      {:error, reason} -> {:error, reason}
    end
  end

  ## Private

  defp base_url(provider), do: Map.get(provider, :base_url) || @default_base_url

  # Exchanges the user's username/password for a short-lived JWT. Only the
  # HTTP status code drives the return value here -- never the response
  # body -- so a provider echoing request details back on failure can never
  # end up inside one of our error tuples (and from there, a caller's logs).
  defp login(provider) do
    body = %{username: provider.username, password: provider.password}

    case Req.post(base_url(provider) <> "/api/v1/login",
           json: body,
           headers: unauthenticated_headers(provider),
           receive_timeout: @timeout
         ) do
      {:ok, %{status: 200, body: %{"token" => token}}} -> {:ok, token}
      {:ok, %{status: 401}} -> {:error, :authentication_failed}
      {:ok, %{status: status}} -> {:error, {:login_failed, status}}
      {:error, reason} -> {:error, {:transport, reason}}
    end
  end

  defp request(provider, token, method, path, opts \\ []) do
    opts =
      opts
      |> Keyword.put(:headers, [
        {"Authorization", "Bearer " <> token} | unauthenticated_headers(provider)
      ])
      |> Keyword.put(:receive_timeout, @timeout)
      |> Keyword.put(:url, base_url(provider) <> path)
      |> Keyword.put(:method, method)

    case Req.request(opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: 401}} ->
        {:error, :authentication_failed}

      # OpenSubtitles returns 406 when the account's daily download quota is
      # exhausted -- distinct from 429 rate limiting below. Keyed on status
      # code, never on body text, per Provider's shared error vocabulary.
      {:ok, %{status: 406}} ->
        {:error, :quota_exceeded}

      {:ok, %{status: 429}} ->
        {:error, :rate_limited}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  # decode_body: false keeps the response as a raw binary regardless of its
  # content-type. download/2 promises {:ok, binary()}; without this, Req
  # would auto-decode a JSON-served subtitle into a map and silently break
  # that contract. Mirrors Mydia.Subtitles.Provider.Relay.fetch_content/1.
  defp fetch_content(url) do
    case Req.get(url, headers: [{"User-Agent", user_agent()}], decode_body: false) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("OpenSubtitles subtitle content fetch failed", status: status)
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  defp unauthenticated_headers(provider) do
    [
      {"Api-Key", provider.api_key},
      {"Content-Type", "application/json"},
      {"User-Agent", user_agent()}
    ]
  end

  defp user_agent, do: Mydia.Metadata.Provider.HTTP.user_agent()

  # GET /api/v1/infos/user has no reference implementation anywhere in
  # metadata-relay/ (client.ex, handler.ex, and auth.ex never call it), so
  # its wire format is unverified against this repo's known-working code,
  # unlike search/download/login above. Requiring downloads_count and
  # allowed_downloads to both be present *and* integers means a wrong
  # guess fails loudly as {:error, {:invalid_quota_response, data}} instead
  # of silently reporting a well-formed but meaningless
  # %QuotaInfo{remaining: 0, total: 0} -- which would read to a user as an
  # exhausted or broken account when the truth is just "unknown". vip is
  # the only genuinely optional field here, so it alone keeps a default.
  defp extract_quota(%{"downloads_count" => used, "allowed_downloads" => total} = data)
       when is_integer(used) and is_integer(total) do
    remaining =
      case data["remaining_downloads"] do
        remaining when is_integer(remaining) -> remaining
        _ -> max(total - used, 0)
      end

    {:ok,
     %QuotaInfo{
       type: :limited,
       provider_type: :opensubtitles,
       remaining: remaining,
       total: total,
       reset_at: nil,
       vip: data["vip"] || false
     }}
  end

  defp extract_quota(data), do: {:error, {:invalid_quota_response, data}}

  defp build_query(params) do
    params
    |> Map.take([:languages, :imdb_id, :tmdb_id, :season_number, :episode_number, :query])
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    |> maybe_put_query(params, :file_hash, "moviehash")
    |> maybe_put_query(params, :file_size, "moviebytesize")
    |> maybe_put_media_type(params)
  end

  # Mirrors MetadataRelay.OpenSubtitles.Handler.build_search_params/1's
  # file_hash -> moviehash and file_size -> moviebytesize renames. A
  # moviehash search without its companion moviebytesize is the exact bug a
  # prior fix round found and closed on the relay adapter's hash matching,
  # so both must travel together here too.
  defp maybe_put_query(query, params, key, param_name) do
    case Map.get(params, key) do
      nil -> query
      "" -> query
      value -> Map.put(query, param_name, value)
    end
  end

  # handler.ex only forwards media_type when it is exactly "movie" or
  # "episode" -- any other value is silently dropped rather than passed
  # through as-is, so mirror that instead of forwarding arbitrary strings.
  defp maybe_put_media_type(query, %{media_type: type}) when type in ["movie", "episode"],
    do: Map.put(query, "type", type)

  defp maybe_put_media_type(query, _params), do: query

  # OpenSubtitles nests the downloadable file inside each search entry's
  # attributes. Mirrors MetadataRelay.OpenSubtitles.Handler.transform_subtitle/1
  # and get_file_id/1: the file's own file_id is preferred, but when
  # attributes.files is missing or its first entry lacks a file_id, fall back
  # to the entry's top-level subtitle id rather than dropping the result.
  defp extract_result(entry) do
    attrs = entry["attributes"] || %{}
    file = first_file(attrs["files"])
    file_id = (file && file["file_id"]) || entry["id"]
    language = attrs["language"]

    %{
      "file_id" => file_id,
      "file_name" => (file && file["file_name"]) || attrs["release"],
      "language" => language,
      "format" => attrs["format"] || "srt",
      "rating" => attrs["ratings"],
      "download_count" => attrs["download_count"],
      "hearing_impaired" => attrs["hearing_impaired"] || false,
      "moviehash_match" => attrs["moviehash_match"] || false,
      "subtitle_hash" => synthesize_subtitle_hash(file_id, language)
    }
  end

  defp first_file([%{"file_id" => _} = file | _rest]), do: file
  defp first_file(_not_a_matching_list), do: nil

  # OpenSubtitles never returns a content hash for the subtitle file itself,
  # so synthesize a deterministic one from (file_id, language) -- same
  # formula as Mydia.Subtitles.Provider.Relay.synthesize_subtitle_hash/2 and
  # Mydia.Subtitles.generate_subtitle_hash/1 (subtitles.ex is off limits for
  # this task, so this mirrors rather than calls it): stable across repeated
  # searches for the same subtitle, but not a hash of the file's contents.
  defp synthesize_subtitle_hash(file_id, language) do
    :crypto.hash(:sha256, "#{file_id}-#{language}")
    |> Base.encode16(case: :lower)
  end
end
