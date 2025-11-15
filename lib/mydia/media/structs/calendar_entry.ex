defmodule Mydia.Media.Structs.CalendarEntry do
  @moduledoc """
  Represents a calendar entry for either an episode or a movie.

  This struct provides compile-time safety for calendar data,
  unifying the structure for both episodes and movies in calendar views.

  ## Fields

  Common fields:
  - `:id` - The ID of the episode or media item
  - `:type` - Either "episode" or "movie"
  - `:air_date` - The air/release date
  - `:title` - The episode title or movie title
  - `:media_item_id` - The associated media item ID
  - `:media_item_title` - The parent show title or movie title
  - `:media_item_type` - The media item type ("tv_show" or "movie")
  - `:has_files` - Whether files exist for this entry
  - `:has_downloads` - Whether downloads exist for this entry

  Episode-specific fields:
  - `:season_number` - The season number (nil for movies)
  - `:episode_number` - The episode number (nil for movies)
  """

  @enforce_keys [
    :id,
    :type,
    :air_date,
    :title,
    :media_item_id,
    :media_item_title,
    :media_item_type,
    :has_files,
    :has_downloads
  ]

  defstruct [
    :id,
    :type,
    :air_date,
    :title,
    :season_number,
    :episode_number,
    :media_item_id,
    :media_item_title,
    :media_item_type,
    :has_files,
    :has_downloads
  ]

  @type t :: %__MODULE__{
          id: integer(),
          type: String.t(),
          air_date: Date.t(),
          title: String.t(),
          season_number: integer() | nil,
          episode_number: integer() | nil,
          media_item_id: integer(),
          media_item_title: String.t(),
          media_item_type: String.t(),
          has_files: boolean(),
          has_downloads: boolean()
        }

  @doc """
  Creates a new CalendarEntry struct for an episode.

  ## Examples

      iex> new_episode(
      ...>   id: 1,
      ...>   air_date: ~D[2024-01-15],
      ...>   title: "Pilot",
      ...>   season_number: 1,
      ...>   episode_number: 1,
      ...>   media_item_id: 10,
      ...>   media_item_title: "Great Show",
      ...>   media_item_type: "tv_show",
      ...>   has_files: true,
      ...>   has_downloads: false
      ...> )
      %CalendarEntry{type: "episode", ...}
  """
  def new_episode(attrs) do
    attrs
    |> Keyword.put(:type, "episode")
    |> then(&struct!(__MODULE__, &1))
  end

  @doc """
  Creates a new CalendarEntry struct for a movie.

  ## Examples

      iex> new_movie(
      ...>   id: 1,
      ...>   air_date: ~D[2024-01-15],
      ...>   title: "Great Movie",
      ...>   media_item_id: 1,
      ...>   media_item_title: "Great Movie",
      ...>   media_item_type: "movie",
      ...>   has_files: false,
      ...>   has_downloads: true
      ...> )
      %CalendarEntry{type: "movie", season_number: nil, episode_number: nil, ...}
  """
  def new_movie(attrs) do
    attrs
    |> Keyword.put(:type, "movie")
    |> Keyword.put_new(:season_number, nil)
    |> Keyword.put_new(:episode_number, nil)
    |> then(&struct!(__MODULE__, &1))
  end
end
