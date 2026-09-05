defmodule Mydia.Media.MediaItemTest do
  use Mydia.DataCase, async: true

  alias Mydia.Media.MediaItem

  describe "provider-id uniqueness scoped by media type" do
    test "allows movie and tv_show to share the same tmdb_id" do
      shared_id = System.unique_integer([:positive])

      {:ok, _movie} =
        %MediaItem{}
        |> MediaItem.changeset(%{
          type: "movie",
          title: "Movie Shared",
          year: 2024,
          tmdb_id: shared_id
        })
        |> Repo.insert()

      assert {:ok, _series} =
               %MediaItem{}
               |> MediaItem.changeset(%{
                 type: "tv_show",
                 title: "Series Shared",
                 year: 2024,
                 tmdb_id: shared_id
               })
               |> Repo.insert()
    end

    test "rejects two movies sharing the same tmdb_id" do
      shared_id = System.unique_integer([:positive])

      {:ok, _movie1} =
        %MediaItem{}
        |> MediaItem.changeset(%{
          type: "movie",
          title: "Movie 1",
          year: 2024,
          tmdb_id: shared_id
        })
        |> Repo.insert()

      assert {:error, changeset} =
               %MediaItem{}
               |> MediaItem.changeset(%{
                 type: "movie",
                 title: "Movie 2",
                 year: 2024,
                 tmdb_id: shared_id
               })
               |> Repo.insert()

      assert %{tmdb_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "allows movie and tv_show to share the same tvdb_id" do
      shared_id = System.unique_integer([:positive])

      {:ok, _movie} =
        %MediaItem{}
        |> MediaItem.changeset(%{
          type: "movie",
          title: "Movie Shared TVDB",
          year: 2024,
          tvdb_id: shared_id
        })
        |> Repo.insert()

      assert {:ok, _series} =
               %MediaItem{}
               |> MediaItem.changeset(%{
                 type: "tv_show",
                 title: "Series Shared TVDB",
                 year: 2024,
                 tvdb_id: shared_id
               })
               |> Repo.insert()
    end

    test "rejects two tv_shows sharing the same tvdb_id" do
      shared_id = System.unique_integer([:positive])

      {:ok, _series1} =
        %MediaItem{}
        |> MediaItem.changeset(%{
          type: "tv_show",
          title: "Series 1",
          year: 2024,
          tvdb_id: shared_id
        })
        |> Repo.insert()

      assert {:error, changeset} =
               %MediaItem{}
               |> MediaItem.changeset(%{
                 type: "tv_show",
                 title: "Series 2",
                 year: 2024,
                 tvdb_id: shared_id
               })
               |> Repo.insert()

      assert %{tvdb_id: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "changeset/2 metadata_source" do
    test "casts :tvdb" do
      changeset =
        MediaItem.changeset(%MediaItem{}, %{
          type: "tv_show",
          title: "Breaking Bad",
          metadata_source: :tvdb
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :metadata_source) == :tvdb
    end

    test "casts :tmdb" do
      changeset =
        MediaItem.changeset(%MediaItem{}, %{
          type: "tv_show",
          title: "Ghost in the Shell",
          metadata_source: :tmdb
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :metadata_source) == :tmdb
    end

    test "rejects an unknown metadata_source" do
      changeset =
        MediaItem.changeset(%MediaItem{}, %{
          type: "tv_show",
          title: "Breaking Bad",
          metadata_source: "imdb"
        })

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :metadata_source)
    end

    test "is optional (nil for movies)" do
      changeset =
        MediaItem.changeset(%MediaItem{}, %{type: "movie", title: "The Matrix", year: 1999})

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :metadata_source) == nil
    end
  end
end
