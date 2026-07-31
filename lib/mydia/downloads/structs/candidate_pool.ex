defmodule Mydia.Downloads.Structs.CandidatePool do
  @moduledoc """
  Library items loaded once so many releases can be scored against one read.

  `TorrentMatcher.find_top_candidates/2` loads the whole library on every call,
  which is fine when it runs once per torrent at row-creation time and is not
  fine for a scan that runs on an interval over every torrent in every client.
  Callers in that position build a pool once and pass it to
  `TorrentMatcher.find_top_candidates_in/3`.
  """

  alias Mydia.Media
  alias Mydia.Media.MediaItem

  @enforce_keys [:movies, :tv_shows]
  defstruct [:movies, :tv_shows]

  @type t :: %__MODULE__{
          movies: [MediaItem.t()],
          tv_shows: [MediaItem.t()]
        }

  @doc """
  Loads every movie and TV show in one query each.

  ## Options
    - `:monitored_only` - restrict both sides to monitored items (default `false`)
  """
  @spec load(keyword()) :: t()
  def load(opts \\ []) do
    base = if Keyword.get(opts, :monitored_only, false), do: [monitored: true], else: []

    %__MODULE__{
      movies: Media.list_media_items([{:type, "movie"} | base]),
      tv_shows: Media.list_media_items([{:type, "tv_show"} | base])
    }
  end
end
