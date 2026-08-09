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

  @default_sort %{field: :title, direction: :asc}

  @doc """
  Sorts `items` according to `sort`.

  `progress` maps a media item id to a `Mydia.Playback.Progress` struct. Only
  the watch-state fields consult it; pass an empty map for everything else.
  """
  @spec sort([struct()], map() | nil, map()) :: [struct()]
  def sort(items, sort, progress \\ %{})

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

  # Key extraction. Returning nil puts the item in the unknown group.

  defp mapper_for(:title, _progress), do: &downcased_title/1
  defp mapper_for(:year, _progress), do: & &1.year
  defp mapper_for(:added_at, _progress), do: & &1.inserted_at
  defp mapper_for(:rating, _progress), do: &MetadataAccess.get_field(&1, :vote_average)
  defp mapper_for(_unknown, _progress), do: &downcased_title/1

  # Comparison terms. Date and DateTime need their module, since plain term
  # order on those structs compares :day before :month before :year.

  defp sorter_for(:added_at, direction), do: {direction, DateTime}
  defp sorter_for(_field, direction), do: direction

  defp downcased_title(%{title: title}) when is_binary(title), do: String.downcase(title)
  defp downcased_title(_item), do: nil
end
