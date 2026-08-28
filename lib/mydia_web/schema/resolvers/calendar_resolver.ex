defmodule MydiaWeb.Schema.Resolvers.CalendarResolver do
  @moduledoc """
  Resolves the player's calendar: episodes and movies inside a date window.

  Deliberately narrower than `MydiaWeb.CalendarLive.Index`, which is an operator
  view and surfaces downloading and missing state. The player is a playback
  client, so availability is only ever "there is a file" or "there is not", and
  `has_downloads` is never exposed.
  """

  alias Mydia.Library.MediaFile
  alias Mydia.Media
  alias Mydia.Repo

  import Ecto.Query

  @doc """
  Entries between `start` and `end`, both bounds inclusive.

  Ordered the way the player renders them: by air date, then playable entries
  first, then parent title. Sorting here rather than on the client keeps the
  order testable in one place.
  """
  def calendar(_parent, %{start: start_date, end: end_date}, _resolution) do
    episodes = Media.list_episodes_by_air_date(start_date, end_date, monitored: nil)
    movies = Media.list_movies_by_release_date(start_date, end_date, monitored: nil)

    entries =
      (episodes ++ movies)
      |> Enum.sort_by(
        # `Date.to_erl/1` turns the date into a plain `{year, month, day}`
        # tuple. A bare `%Date{}` inside a sort tuple compares by struct
        # field order (`day` before `month` before `year`), which is not
        # chronological order. Do not "simplify" this back to `&1.air_date`.
        &{Date.to_erl(&1.air_date), !&1.has_files, &1.media_item_title},
        :asc
      )

    {:ok, entries}
  end

  @doc """
  Playable files for one entry.

  Returns `[]` rather than nil when nothing is playable, so the client can treat
  `files.isNotEmpty` as the single definition of playable.
  """
  def files(%{has_files: false}, _args, _resolution), do: {:ok, []}

  def files(%{type: "episode", id: episode_id}, _args, _resolution) do
    {:ok, Repo.all(from f in MediaFile, where: f.episode_id == ^episode_id)}
  end

  def files(%{type: "movie", media_item_id: media_item_id}, _args, _resolution) do
    {:ok, Repo.all(from f in MediaFile, where: f.media_item_id == ^media_item_id)}
  end
end
