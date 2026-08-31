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
end
