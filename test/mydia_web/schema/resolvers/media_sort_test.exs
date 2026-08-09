defmodule MydiaWeb.Schema.Resolvers.MediaSortTest do
  use ExUnit.Case, async: true

  alias Mydia.Media.MediaItem
  alias Mydia.Metadata.Structs.MediaMetadata
  alias MydiaWeb.Schema.Resolvers.MediaSort

  defp item(id, attrs) do
    {meta_attrs, item_attrs} =
      Map.split(attrs, [
        :vote_average,
        :popularity,
        :content_rating,
        :runtime,
        :release_date,
        :episode_run_time,
        :first_air_date
      ])

    type = Map.get(item_attrs, :type, "movie")

    metadata =
      if map_size(meta_attrs) == 0 do
        nil
      else
        struct(
          %MediaMetadata{
            provider_id: "x",
            provider: :tmdb,
            media_type: if(type == "tv_show", do: :tv_show, else: :movie)
          },
          meta_attrs
        )
      end

    struct(%MediaItem{id: id, metadata: metadata}, Map.put(item_attrs, :type, type))
  end

  defp many(count) do
    for n <- 1..count, do: item("#{n}", %{title: "Title #{n}"})
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

  describe "runtime" do
    test "sorts movies by runtime" do
      items = [
        item("long", %{title: "A", runtime: 180}),
        item("short", %{title: "B", runtime: 90})
      ]

      assert ids(MediaSort.sort(items, %{field: :runtime, direction: :asc})) == ["short", "long"]
      assert ids(MediaSort.sort(items, %{field: :runtime, direction: :desc})) == ["long", "short"]
    end

    test "falls back to the first episode_run_time for shows" do
      items = [
        item("hour", %{type: "tv_show", title: "A", episode_run_time: [60]}),
        item("half", %{type: "tv_show", title: "B", episode_run_time: [30]})
      ]

      assert ids(MediaSort.sort(items, %{field: :runtime, direction: :asc})) == ["half", "hour"]
    end

    test "a show with an empty episode_run_time sorts last" do
      items = [
        item("none", %{type: "tv_show", title: "A", episode_run_time: []}),
        item("half", %{type: "tv_show", title: "B", episode_run_time: [30]})
      ]

      assert ids(MediaSort.sort(items, %{field: :runtime, direction: :desc})) == ["half", "none"]
    end
  end

  describe "popularity" do
    test "sorts by popularity" do
      items = [
        item("hot", %{title: "A", popularity: 900.5}),
        item("cold", %{title: "B", popularity: 1.2})
      ]

      assert ids(MediaSort.sort(items, %{field: :popularity, direction: :desc})) == [
               "hot",
               "cold"
             ]
    end
  end

  describe "content_rating" do
    test "sorts by content rating and keeps ties in input order" do
      items = [
        item("pg1", %{title: "A", content_rating: "PG"}),
        item("g", %{title: "B", content_rating: "G"}),
        item("pg2", %{title: "C", content_rating: "PG"})
      ]

      assert ids(MediaSort.sort(items, %{field: :content_rating, direction: :asc})) ==
               ["g", "pg1", "pg2"]

      # The tie group keeps its order even reversed. This is the defect that
      # Enum.reverse/1 used to introduce.
      assert ids(MediaSort.sort(items, %{field: :content_rating, direction: :desc})) ==
               ["pg1", "pg2", "g"]
    end
  end

  describe "release_date" do
    test "sorts movies by release date chronologically" do
      items = [
        item("new", %{title: "A", release_date: ~D[2026-01-01]}),
        item("old", %{title: "B", release_date: ~D[1999-12-31]})
      ]

      assert ids(MediaSort.sort(items, %{field: :release_date, direction: :asc})) == [
               "old",
               "new"
             ]
    end

    test "falls back to first_air_date for shows" do
      items = [
        item("new", %{type: "tv_show", title: "A", first_air_date: ~D[2026-01-01]}),
        item("old", %{type: "tv_show", title: "B", first_air_date: ~D[1999-12-31]})
      ]

      assert ids(MediaSort.sort(items, %{field: :release_date, direction: :desc})) == [
               "new",
               "old"
             ]
    end
  end

  describe "random" do
    test "the same seed always yields the same order" do
      items = many(50)

      first = MediaSort.sort(items, %{field: :random, direction: :asc, seed: 12_345})
      second = MediaSort.sort(items, %{field: :random, direction: :asc, seed: 12_345})

      assert ids(first) == ids(second)
    end

    test "different seeds yield different orders" do
      items = many(50)

      a = MediaSort.sort(items, %{field: :random, direction: :asc, seed: 1})
      b = MediaSort.sort(items, %{field: :random, direction: :asc, seed: 2})

      assert ids(a) != ids(b)
    end

    test "it is a permutation, losing and duplicating nothing" do
      items = many(50)

      shuffled = MediaSort.sort(items, %{field: :random, direction: :asc, seed: 7})

      assert Enum.sort(ids(shuffled)) == Enum.sort(ids(items))
    end

    test "paging under one seed produces no overlap and no gap" do
      items = many(50)
      sorted = MediaSort.sort(items, %{field: :random, direction: :asc, seed: 99})

      # What the resolver does: re-sort the full list per request, then slice.
      page_one = sorted |> Enum.take(20) |> ids()

      page_two =
        items
        |> MediaSort.sort(%{field: :random, direction: :asc, seed: 99})
        |> Enum.drop(20)
        |> Enum.take(20)
        |> ids()

      assert page_one -- page_two == page_one
      assert length(Enum.uniq(page_one ++ page_two)) == 40
    end

    test "a missing seed still returns a stable permutation" do
      items = many(20)

      first = MediaSort.sort(items, %{field: :random, direction: :asc})
      second = MediaSort.sort(items, %{field: :random, direction: :asc})

      assert ids(first) == ids(second)
      assert Enum.sort(ids(first)) == Enum.sort(ids(items))
    end
  end
end
