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

  Files are attached to each entry here rather than resolved per-field:
  Absinthe calls a field resolver once per entry, so a per-item `Repo.all`
  on `:files` would issue one query per entry (a realistic response is 60+,
  since the window is library-wide across 120 days). Batch-loading keeps the
  query count constant, the same way `Mydia.Playback.OnDeck` attaches
  `:files` to each `OnDeckEntry` before the continue-watching resolver ever
  runs. See `MydiaWeb.Schema.Resolvers.DiscoveryResolver.continue_watching/3`.
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
      |> attach_files()

    {:ok, entries}
  end

  # Two whole-collection queries, not one per entry: episode files keyed by
  # `episode_id`, movie files keyed by `media_item_id`. A movie entry's `id`
  # and `media_item_id` are equal, which is exactly the pair that hides a
  # mistake here if the wrong key is used for the wrong type. Episodes have
  # no `media_item_id` file rows and movies have no `episode_id` file rows,
  # so a mix-up would silently return `[]` instead of raising.
  defp attach_files(entries) do
    episode_ids = for %{type: "episode", has_files: true, id: id} <- entries, do: id

    movie_media_item_ids =
      for %{type: "movie", has_files: true, media_item_id: id} <- entries, do: id

    files_by_episode_id = load_files_by(:episode_id, episode_ids)
    files_by_media_item_id = load_files_by(:media_item_id, movie_media_item_ids)

    Enum.map(entries, fn
      %{type: "episode"} = entry ->
        %{entry | files: Map.get(files_by_episode_id, entry.id, [])}

      %{type: "movie"} = entry ->
        %{entry | files: Map.get(files_by_media_item_id, entry.media_item_id, [])}
    end)
  end

  defp load_files_by(_key_field, []), do: %{}

  defp load_files_by(:episode_id, episode_ids) do
    Repo.all(from f in MediaFile, where: f.episode_id in ^episode_ids)
    |> Enum.group_by(& &1.episode_id)
  end

  defp load_files_by(:media_item_id, media_item_ids) do
    Repo.all(from f in MediaFile, where: f.media_item_id in ^media_item_ids)
    |> Enum.group_by(& &1.media_item_id)
  end
end
