defmodule Mydia.Subtitles.Provider.Gestdown do
  @moduledoc """
  Subtitle provider backed by api.gestdown.info, which serves Addic7ed.

  This is the second zero-configuration provider. It needs no key and no
  account, so it is enabled by default and gives a fresh install an upstream
  that fails independently of OpenSubtitles. That independence is the reason it
  is here: the relay and a direct OpenSubtitles account share one upstream, so
  neither covers the other going down.

  It serves television only, keyed on a TVDB id, and offers no file hashing. Its
  results therefore compete on metadata rather than on exact file matches, which
  is why `capabilities/0` narrows it rather than letting the chain discover the
  limits one wasted request at a time.
  """

  @behaviour Mydia.Subtitles.Provider

  require Logger

  alias Mydia.Subtitles.Provider.Gestdown.Languages
  alias Mydia.Subtitles.Provider.QuotaInfo
  alias Mydia.Subtitles.Provider.SearchResult

  @default_base_url "https://api.gestdown.info"
  @timeout 10_000

  @impl true
  def search(config, params) do
    with {:ok, tvdb_id} <- fetch_tvdb_id(params),
         {:ok, season, episode} <- fetch_episode(params),
         {:ok, show_id} <- find_show(config, tvdb_id) do
      results =
        params
        |> requested_languages()
        |> Enum.flat_map(&search_language(config, show_id, season, episode, &1))

      {:ok, results}
    else
      {:error, :show_not_found} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  # Returns the subtitle body, not a URL. `Provider.Relay` settled this contract
  # in the player plan's Task 5: the behaviour documents `{:ok, content}`, and
  # both are binaries, so an adapter returning a URL here would be written to
  # disk as the subtitle instead of failing loudly.
  @impl true
  def download(config, %{file_id: file_id}) do
    fetch_body(base_url(config) <> "/subtitles/download/" <> to_string(file_id))
  end

  @impl true
  def validate_config(config), do: {:ok, config}

  @impl true
  def quota_info(_config), do: {:ok, QuotaInfo.unlimited(:gestdown)}

  @impl true
  def capabilities do
    %{
      media_types: [:episode],
      search_keys: [:tvdb_id],
      requires_credentials: false,
      quota: :unlimited
    }
  end

  ## Private

  defp base_url(config), do: Map.get(config, :base_url) || @default_base_url

  defp fetch_tvdb_id(params) do
    case Map.get(params, :tvdb_id) do
      nil -> {:error, :insufficient_search_criteria}
      "" -> {:error, :insufficient_search_criteria}
      id -> {:ok, to_string(id)}
    end
  end

  defp fetch_episode(params) do
    season = Map.get(params, :season_number)
    episode = Map.get(params, :episode_number)

    if is_integer(season) and is_integer(episode) do
      {:ok, season, episode}
    else
      {:error, :insufficient_search_criteria}
    end
  end

  # Languages with no Gestdown name are dropped rather than guessed at.
  defp requested_languages(params) do
    params
    |> Map.get(:languages, "en")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.flat_map(fn code ->
      case Languages.to_name(code) do
        {:ok, name} ->
          [{code, name}]

        :error ->
          Logger.debug("Gestdown has no name for language", code: code)
          []
      end
    end)
  end

  defp find_show(config, tvdb_id) do
    case get(config, "/shows/external/tvdb/#{tvdb_id}") do
      {:ok, %{"shows" => [%{"id" => id} | _rest]}} -> {:ok, id}
      {:ok, _no_shows} -> {:error, :show_not_found}
      {:error, :not_found} -> {:error, :show_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp search_language(config, show_id, season, episode, {code, name}) do
    path = "/subtitles/get/#{show_id}/#{season}/#{episode}/#{URI.encode(name)}"

    case get(config, path) do
      {:ok, %{"matchingSubtitles" => subtitles}} when is_list(subtitles) ->
        subtitles
        |> Enum.filter(&complete?/1)
        |> Enum.map(&to_search_result(&1, code))

      {:ok, _unexpected} ->
        []

      {:error, :not_found} ->
        []

      {:error, reason} ->
        Logger.warning("Gestdown language search failed",
          language: code,
          reason: inspect(reason)
        )

        []
    end
  end

  # `completed: false` marks a subtitle still being worked on upstream. Offering
  # a partial subtitle as a finished one is worse than not offering it.
  defp complete?(%{"completed" => false}), do: false
  defp complete?(_subtitle), do: true

  defp to_search_result(subtitle, code) do
    %SearchResult{
      file_id: subtitle["subtitleId"],
      language: code,
      # Addic7ed publishes SubRip. The API states no format, and every observed
      # download is SRT.
      format: "srt",
      subtitle_hash: subtitle["subtitleId"],
      file_name: subtitle["version"],
      rating: nil,
      download_count: subtitle["downloadCount"] || 0,
      hearing_impaired: subtitle["hearingImpaired"] || false,
      moviehash_match: false
    }
  end

  # Raw bytes, not JSON. `decode_body: false` matters because Req would
  # otherwise try to interpret a subtitle body by content type.
  defp fetch_body(url) do
    case Req.get(url,
           decode_body: false,
           headers: [{"user-agent", Mydia.Metadata.Provider.HTTP.user_agent()}],
           receive_timeout: @timeout
         ) do
      {:ok, %{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, %{reason: reason}} -> {:error, {:transport, reason}}
      {:error, reason} -> {:error, {:transport, reason}}
    end
  end

  defp get(config, path) do
    url = base_url(config) <> path

    case Req.get(url,
           headers: [{"user-agent", Mydia.Metadata.Provider.HTTP.user_agent()}],
           receive_timeout: @timeout
         ) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        Jason.decode(body)

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: 429}} ->
        {:error, :rate_limited}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, %{reason: reason}} ->
        {:error, {:transport, reason}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end
end
