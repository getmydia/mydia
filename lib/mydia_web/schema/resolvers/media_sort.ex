defmodule MydiaWeb.Schema.Resolvers.MediaSort do
  @moduledoc """
  Ordering for the `movies` and `tv_shows` connections.

  Sorting runs in memory over the whole list before pagination, so every
  comparison here has to be total. A partial order would let page boundaries
  shift between requests, which surfaces as duplicated and skipped items
  during infinite scroll rather than as anything that looks like a sort bug.

  Two rules hold for every field:

    * Ties keep their input order. `Enum.sort_by/3` is stable in both
      directions, which is why direction is passed to the sorter rather than
      applied afterwards with `Enum.reverse/1`.
    * Items whose key is unknown sort last, ascending and descending alike.
      A film with no rating should lead neither the highest-rated nor the
      lowest-rated list.
  """

  alias Mydia.Metadata.Access, as: MetadataAccess
  alias Mydia.Playback

  @default_sort %{field: :title, direction: :asc}

  # Used when a client selects random without minting a seed. Any fixed value
  # works; what matters is that the order stays stable across page requests.
  @default_random_seed 0

  @doc """
  Sorts `items` according to `sort`.

  `progress` maps a media item id to a `Mydia.Playback.Progress` struct. Only
  the watch-state fields consult it; pass an empty map for everything else.
  """
  @spec sort([struct()], map() | nil, map()) :: [struct()]
  def sort(items, sort, progress \\ %{})

  def sort(items, %{field: :random} = sort, _progress) do
    seed = Map.get(sort, :seed) || @default_random_seed

    # phash2 is deterministic across processes and restarts, which :rand is
    # not. Pagination re-sorts the whole list per request, so the permutation
    # has to be reproducible or infinite scroll duplicates and skips items.
    Enum.sort_by(items, &:erlang.phash2({&1.id, seed}))
  end

  def sort(items, %{field: field, direction: direction}, progress)
      when direction in [:asc, :desc] do
    mapper = mapper_for(field, progress)

    {known, unknown} =
      items
      |> Enum.map(&{mapper.(&1), &1})
      |> Enum.split_with(fn {key, _item} -> key != nil end)

    sorted =
      known
      |> Enum.sort_by(&elem(&1, 0), sorter_for(field, direction))
      |> Enum.map(&elem(&1, 1))

    sorted ++ Enum.map(unknown, &elem(&1, 1))
  end

  def sort(items, _sort, progress), do: sort(items, @default_sort, progress)

  @doc """
  Builds the `media_item_id => progress` map the watch-state fields need.

  Returns an empty map for every other field, and when there is no signed-in
  user, so callers can invoke it unconditionally. One query, not one per item:
  a per-item `Playback.get_progress/2` here would be an N+1 across the whole
  library.
  """
  @spec progress_map(struct() | nil, atom()) :: map()
  def progress_map(nil, _field), do: %{}

  def progress_map(user, field) when field in [:last_played, :watch_state] do
    user.id
    |> Playback.list_user_progress()
    |> Enum.filter(&is_nil(&1.episode_id))
    |> Map.new(&{&1.media_item_id, &1})
  end

  def progress_map(_user, _field), do: %{}

  @doc """
  Downgrades a sort the caller cannot actually be served.

  A signed-out caller has no watch history, so `:last_played` and
  `:watch_state` have no answer for them. Returning items in whatever order
  the query happened to produce would look like a broken sort, so those two
  fields fall back to the default instead.
  """
  @spec effective_sort(map() | nil, struct() | nil) :: map() | nil
  def effective_sort(%{field: field}, nil) when field in [:last_played, :watch_state],
    do: @default_sort

  def effective_sort(sort, _user), do: sort

  # Key extraction. Returning nil puts the item in the unknown group.

  defp mapper_for(:title, _progress), do: &downcased_title/1
  defp mapper_for(:year, _progress), do: & &1.year
  defp mapper_for(:added_at, _progress), do: & &1.inserted_at
  defp mapper_for(:rating, _progress), do: &MetadataAccess.get_field(&1, :vote_average)
  defp mapper_for(:runtime, _progress), do: &runtime/1
  defp mapper_for(:popularity, _progress), do: &MetadataAccess.get_field(&1, :popularity)

  defp mapper_for(:content_rating, _progress),
    do: &MetadataAccess.get_field(&1, :content_rating)

  defp mapper_for(:release_date, _progress), do: &release_date/1
  defp mapper_for(:last_played, progress), do: &last_played(&1, progress)
  defp mapper_for(:watch_state, progress), do: &watched?(&1, progress)
  defp mapper_for(_unknown, _progress), do: &downcased_title/1

  # Comparison terms. Date and DateTime need their module, since plain term
  # order on those structs compares :day before :month before :year.

  defp sorter_for(:added_at, direction), do: {direction, DateTime}
  defp sorter_for(:release_date, direction), do: {direction, Date}
  defp sorter_for(:last_played, direction), do: {direction, DateTime}
  defp sorter_for(_field, direction), do: direction

  defp downcased_title(%{title: title}) when is_binary(title), do: String.downcase(title)
  defp downcased_title(_item), do: nil

  # TMDB gives films a scalar `runtime` and shows a list of typical episode
  # lengths, so a show's duration is the head of that list.
  defp runtime(%{type: "tv_show"} = item) do
    item
    |> MetadataAccess.get_field(:episode_run_time)
    |> first_runtime()
  end

  defp runtime(item), do: MetadataAccess.get_field(item, :runtime)

  defp first_runtime([first | _rest]), do: first
  defp first_runtime(value) when is_integer(value), do: value
  defp first_runtime(_value), do: nil

  defp release_date(%{type: "tv_show"} = item),
    do: MetadataAccess.get_field(item, :first_air_date)

  defp release_date(item), do: MetadataAccess.get_field(item, :release_date)

  defp last_played(item, progress) do
    case Map.get(progress, item.id) do
      nil -> nil
      row -> row.last_watched_at
    end
  end

  # An item nobody has started is unwatched, not unknown: it belongs with the
  # other unwatched items rather than at the end of the list. Elixir orders
  # false before true, so ascending puts unwatched first.
  defp watched?(item, progress) do
    case Map.get(progress, item.id) do
      nil -> false
      row -> row.watched
    end
  end
end
