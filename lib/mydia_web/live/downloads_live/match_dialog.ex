defmodule MydiaWeb.DownloadsLive.MatchDialog do
  @moduledoc """
  State and transitions for the downloads match dialog.

  The dialog serves two modes through one struct. `:inflight` corrects a
  download that is still running, where matching to a TV show alone is the
  useful answer: `Mydia.Jobs.MediaImport` resolves each file's episode from its
  own filename, including the `Complete S01-S03` case. `:postimport` re-matches
  a download that already produced exactly one file on disk, where one file
  means one episode, so an episode stays required for TV.

  Every function takes and returns the struct so `MydiaWeb.DownloadsLive.Index`
  holds no dialog logic. Provider calls live here rather than in the LiveView,
  matching `MydiaWeb.Live.Helpers.MediaAddHelpers`.
  """

  alias Mydia.Library.ReleaseParser
  alias Mydia.Media
  alias Mydia.Media.Add
  alias Mydia.Metadata
  alias Mydia.Settings

  @result_limit 10
  @relay_down "Couldn't reach the metadata service. Showing library results only."

  defstruct [
    :download_id,
    :mode,
    :query,
    :type,
    :selected,
    library_results: [],
    external_results: [],
    episodes: [],
    adding: nil,
    error: nil,
    search_warning: nil
  ]

  @type mode :: :inflight | :postimport
  @type media_type :: :movie | :tv_show

  @type t :: %__MODULE__{
          download_id: binary() | nil,
          mode: mode() | nil,
          query: String.t() | nil,
          type: media_type() | nil,
          selected: %{id: binary(), title: String.t(), type: String.t()} | nil,
          library_results: [Mydia.Media.MediaItem.t()],
          external_results: [Mydia.Metadata.Structs.SearchResult.t()],
          episodes: [Mydia.Media.Episode.t()],
          adding: String.t() | nil,
          error: String.t() | nil,
          search_warning: String.t() | nil
        }

  @doc """
  Builds a dialog for `download` in `mode`.

  The download must have `:media_item` preloaded; the type fallback reads it.
  """
  @spec open(map(), mode()) :: t()
  def open(download, mode) when mode in [:inflight, :postimport] do
    title = download.title || ""
    parsed = ReleaseParser.parse(title)

    %__MODULE__{
      download_id: download.id,
      mode: mode,
      query: seed_query(parsed, title),
      type: seed_type(parsed, download)
    }
  end

  @doc """
  Runs the library and provider searches for `query`.

  Queries under two characters clear the lists rather than returning the whole
  library. Any prior selection is dropped, because the operator is looking for
  something else now.
  """
  @spec search(t(), String.t()) :: t()
  def search(%__MODULE__{} = dialog, query) do
    dialog = %{dialog | query: query, selected: nil, episodes: [], error: nil}

    if String.length(String.trim(query)) < 2 do
      %{dialog | library_results: [], external_results: [], search_warning: nil}
    else
      library = Media.list_media_items(search: query, limit: @result_limit)
      {external, warning} = provider_search(dialog.type, query, library)

      %{dialog | library_results: library, external_results: external, search_warning: warning}
    end
  end

  @doc """
  Switches the provider search between movies and TV and re-runs it.

  There is no TMDB multi-search endpoint, so the type is a real choice rather
  than a filter over one result set.
  """
  @spec set_type(t(), media_type()) :: t()
  def set_type(%__MODULE__{} = dialog, type) when type in [:movie, :tv_show] do
    search(%{dialog | type: type}, dialog.query)
  end

  @doc """
  Chooses a library item.

  Movies always submit. A TV show submits at show level in `:inflight`, where
  the import job resolves each file's episode from its filename. In
  `:postimport` the download is one file on disk, which is one episode, so the
  episode list opens instead.
  """
  @spec select(t(), binary()) :: {:submit, {binary(), binary() | nil}} | {:episodes, t()}
  def select(%__MODULE__{} = dialog, media_item_id) do
    item = Media.get_media_item!(media_item_id)

    if item.type == "tv_show" and dialog.mode == :postimport do
      {:episodes, put_selected(dialog, item)}
    else
      {:submit, {item.id, nil}}
    end
  end

  @doc """
  Opens the episode list for a show without submitting.

  This is the "Pick episode" escape on an in-flight TV row, for the download
  that really is one mis-named episode.
  """
  @spec show_episodes(t(), binary()) :: t()
  def show_episodes(%__MODULE__{} = dialog, media_item_id) do
    put_selected(dialog, Media.get_media_item!(media_item_id))
  end

  @doc """
  Submits the chosen show together with the chosen episode.
  """
  @spec select_episode(t(), binary()) :: {:submit, {binary(), binary()}}
  def select_episode(%__MODULE__{selected: %{id: media_item_id}}, episode_id) do
    {:submit, {media_item_id, episode_id}}
  end

  # A relay outage must not empty the dialog: the library half still works and
  # is often all the operator needs.
  defp provider_search(type, query, library) do
    case Metadata.search_cached(Metadata.default_relay_config(), query, media_type: type) do
      {:ok, results} ->
        {results |> reject_known(library, type) |> Enum.take(@result_limit), nil}

      {:error, _reason} ->
        {[], @relay_down}
    end
  end

  # Deduped against the library rows already fetched rather than with a second
  # query. Best effort by design: a library item whose stored title differs
  # from the provider's misses the title search and reappears here, and
  # `Media.Add.from_attrs/3` catches that case with `:already_in_library`.
  defp reject_known(results, library, type) do
    taken =
      library
      |> Enum.filter(&(&1.type == type_string(type)))
      |> Enum.map(&provider_key(&1, type))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    Enum.reject(results, fn result ->
      case Integer.parse(to_string(result.provider_id)) do
        {id, _rest} -> MapSet.member?(taken, id)
        :error -> false
      end
    end)
  end

  defp provider_key(item, :tv_show), do: item.tvdb_id
  defp provider_key(item, :movie), do: item.tmdb_id

  defp put_selected(dialog, item) do
    %{
      dialog
      | selected: %{id: item.id, title: item.title, type: item.type},
        episodes: Media.list_episodes(item.id),
        error: nil
    }
  end

  defp type_string(:tv_show), do: "tv_show"
  defp type_string(:movie), do: "movie"

  defp seed_query(%{title: parsed_title}, _title)
       when is_binary(parsed_title) and parsed_title != "",
       do: parsed_title

  defp seed_query(_parsed, title), do: title

  # An unloaded association is a struct without a `:type` key, so the map
  # patterns below decline it and the movie default applies.
  defp seed_type(%{type: :tv_show}, _download), do: :tv_show
  defp seed_type(%{type: :movie}, _download), do: :movie
  defp seed_type(_parsed, %{media_item: %{type: "tv_show"}}), do: :tv_show
  defp seed_type(_parsed, %{media_item: %{type: "movie"}}), do: :movie
  defp seed_type(_parsed, _download), do: :movie

  @doc """
  Adds a provider result to the library and hands back the new item.

  `:library_path_id` is deliberately not sent, which is what removes the need
  for a library picker here: `Mydia.Library.TargetResolver` resolves the
  destination by `:type_default` and then `:first_compatible`.

  `{:already_in_library, item}` is success, not failure. It means the dedupe in
  `search/2` and the provider disagreed, and the item the operator wanted
  already exists.
  """
  @spec add_external(t(), String.t()) :: {:added, Mydia.Media.MediaItem.t()} | {:error, t()}
  def add_external(%__MODULE__{} = dialog, provider_id) do
    case find_external(dialog, provider_id) do
      nil ->
        {:error,
         %{dialog | adding: nil, error: "That result is no longer available. Search again."}}

      result ->
        case Add.from_provider(result.provider_id, dialog.type, nil, add_opts(result)) do
          {:ok, item} -> {:added, item}
          {:error, {:already_in_library, item}} -> {:added, item}
          {:error, reason} -> {:error, %{dialog | adding: nil, error: add_error(reason)}}
        end
    end
  end

  defp find_external(dialog, provider_id) do
    Enum.find(dialog.external_results, fn result ->
      to_string(result.provider_id) == to_string(provider_id)
    end)
  end

  # A TV search result carries a TVDB id, but Add defaults TV to TMDB. Without
  # this the TVDB id is sent to TMDB and resolves to the wrong show or nothing.
  defp add_opts(result) do
    opts = [
      monitored: true,
      season_monitoring: "all",
      quality_profile_id: Settings.get_default_quality_profile_id()
    ]

    if result.provider == :tvdb, do: Keyword.put(opts, :provider, :tvdb), else: opts
  end

  defp add_error({:metadata, _reason}), do: "Couldn't fetch metadata for that title."
  defp add_error(_reason), do: "Couldn't add that title to your library."
end
