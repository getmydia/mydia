defmodule MydiaWeb.Schema.Resolvers.MediaSortTest do
  use ExUnit.Case, async: true

  alias Mydia.Media.MediaItem
  alias Mydia.Metadata.Structs.MediaMetadata
  alias MydiaWeb.Schema.Resolvers.MediaSort

  defp item(id, attrs) do
    {meta_attrs, item_attrs} = Map.split(attrs, [:vote_average])

    metadata =
      if map_size(meta_attrs) == 0 do
        nil
      else
        struct(
          %MediaMetadata{provider_id: "x", provider: :tmdb, media_type: :movie},
          meta_attrs
        )
      end

    struct(%MediaItem{id: id, type: "movie", metadata: metadata}, item_attrs)
  end

  defp ids(items), do: Enum.map(items, & &1.id)

  describe "title" do
    test "sorts case-insensitively in both directions" do
      items = [item("1", %{title: "banana"}), item("2", %{title: "Apple"})]

      assert ids(MediaSort.sort(items, %{field: :title, direction: :asc})) == ["2", "1"]
      assert ids(MediaSort.sort(items, %{field: :title, direction: :desc})) == ["1", "2"]
    end
  end

  describe "added_at" do
    test "orders chronologically rather than by day-of-month" do
      # Plain term comparison on DateTime structs compares :day before :year,
      # so this pair is ordered wrongly by any non-DateTime-aware sort.
      early = ~U[2020-12-31 00:00:00Z]
      late = ~U[2026-01-01 00:00:00Z]

      items = [
        item("old", %{title: "A", inserted_at: early}),
        item("new", %{title: "B", inserted_at: late})
      ]

      assert ids(MediaSort.sort(items, %{field: :added_at, direction: :asc})) == ["old", "new"]
      assert ids(MediaSort.sort(items, %{field: :added_at, direction: :desc})) == ["new", "old"]
    end
  end

  describe "tie stability" do
    test "equal keys keep input order in both directions" do
      items = [
        item("a", %{title: "same", year: 2000}),
        item("b", %{title: "same", year: 2000}),
        item("c", %{title: "same", year: 2000})
      ]

      assert ids(MediaSort.sort(items, %{field: :year, direction: :asc})) == ["a", "b", "c"]
      assert ids(MediaSort.sort(items, %{field: :year, direction: :desc})) == ["a", "b", "c"]
    end
  end

  describe "nil placement" do
    test "unknown keys sort last in both directions" do
      items = [
        item("none", %{title: "A", year: nil}),
        item("low", %{title: "B", year: 1990}),
        item("high", %{title: "C", year: 2020})
      ]

      assert ids(MediaSort.sort(items, %{field: :year, direction: :asc})) ==
               ["low", "high", "none"]

      assert ids(MediaSort.sort(items, %{field: :year, direction: :desc})) ==
               ["high", "low", "none"]
    end

    test "an unrated item leads neither end of a rating sort" do
      items = [
        item("unrated", %{title: "A"}),
        item("bad", %{title: "B", vote_average: 2.0}),
        item("good", %{title: "C", vote_average: 9.0})
      ]

      assert ids(MediaSort.sort(items, %{field: :rating, direction: :asc})) ==
               ["bad", "good", "unrated"]

      assert ids(MediaSort.sort(items, %{field: :rating, direction: :desc})) ==
               ["good", "bad", "unrated"]
    end
  end

  describe "defaults" do
    test "a nil sort falls back to title ascending" do
      items = [item("1", %{title: "b"}), item("2", %{title: "a"})]

      assert ids(MediaSort.sort(items, nil)) == ["2", "1"]
    end

    test "an unknown field falls back to title but keeps the requested direction" do
      items = [item("1", %{title: "b"}), item("2", %{title: "a"})]

      assert ids(MediaSort.sort(items, %{field: :nonsense, direction: :asc})) == ["2", "1"]
      assert ids(MediaSort.sort(items, %{field: :nonsense, direction: :desc})) == ["1", "2"]
    end
  end
end
