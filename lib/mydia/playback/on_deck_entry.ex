defmodule Mydia.Playback.OnDeckEntry do
  @moduledoc """
  One card on the Continue Watching rail.

  A movie entry carries `media_item`; an episode entry carries `episode` plus
  its `show`. `progress` is nil for a `:next` entry, which by definition has
  never been played. `files` is carried here rather than re-fetched per card so
  building the GraphQL response adds no queries.
  """

  alias Mydia.Library.MediaFile
  alias Mydia.Media.{Episode, MediaItem}
  alias Mydia.Playback.Progress

  @type kind :: :movie | :episode
  @type state :: :continue | :next

  @type t :: %__MODULE__{
          kind: kind(),
          state: state(),
          media_item: MediaItem.t() | nil,
          episode: Episode.t() | nil,
          show: MediaItem.t() | nil,
          progress: Progress.t() | nil,
          files: [MediaFile.t()],
          sort_at: DateTime.t()
        }

  defstruct [:kind, :state, :media_item, :episode, :show, :progress, :sort_at, files: []]

  @doc """
  The rail identity for an entry: the movie id or the episode id.

  Used as the sort tiebreak so ordering is deterministic when two entries share
  a timestamp, which a bulk watched-import makes common.
  """
  @spec id(t()) :: binary()
  def id(%__MODULE__{kind: :movie, media_item: %{id: id}}), do: id
  def id(%__MODULE__{kind: :episode, episode: %{id: id}}), do: id
end
