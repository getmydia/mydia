defmodule Mydia.Library.TargetResolverTest do
  use Mydia.DataCase, async: true

  import Mydia.SettingsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Library.TargetResolver
  alias Mydia.Settings

  defp movie(attrs \\ %{}) do
    media_item_fixture(Map.merge(%{type: "movie", title: "A Movie", year: 2024}, attrs))
  end

  defp file_in(media_item, library_path, relative_path) do
    {:ok, file} =
      Mydia.Library.create_media_file(%{
        media_item_id: media_item.id,
        library_path_id: library_path.id,
        relative_path: relative_path,
        path: Path.join(library_path.path, relative_path)
      })

    file
  end

  describe "resolve/2 step order" do
    test "a download override wins over everything" do
      chosen = library_path_fixture(%{type: "movies"})
      override = library_path_fixture(%{type: "movies"})
      item = movie(%{library_path_id: chosen.id})

      download = %Mydia.Downloads.Download{
        library_path_id: override.id,
        library_path: override
      }

      assert {:ok, resolved, :download_override} =
               TargetResolver.resolve(item, download: download)

      assert resolved.id == override.id
    end

    test "a download override still applies when the association is not preloaded" do
      chosen = library_path_fixture(%{type: "movies"})
      override = library_path_fixture(%{type: "movies"})
      item = movie(%{library_path_id: chosen.id})

      download = %Mydia.Downloads.Download{
        library_path_id: override.id,
        library_path: %Ecto.Association.NotLoaded{
          __field__: :library_path,
          __owner__: Mydia.Downloads.Download,
          __cardinality__: :one
        }
      }

      assert {:ok, resolved, :download_override} =
               TargetResolver.resolve(item, download: download)

      assert resolved.id == override.id
    end

    test "an explicit target wins over existing files" do
      chosen = library_path_fixture(%{type: "movies"})
      elsewhere = library_path_fixture(%{type: "movies"})
      item = movie(%{library_path_id: chosen.id})
      file_in(item, elsewhere, "A Movie (2024)/a.mkv")

      assert {:ok, resolved, :explicit} = TargetResolver.resolve(item)
      assert resolved.id == chosen.id
    end

    test "existing files win over the type default" do
      with_files = library_path_fixture(%{type: "movies"})
      default = library_path_fixture(%{type: "movies"})
      {:ok, _} = Settings.set_default_library(default, :movies)

      item = movie()
      file_in(item, with_files, "A Movie (2024)/a.mkv")

      assert {:ok, resolved, :existing_files} = TargetResolver.resolve(item)
      assert resolved.id == with_files.id
    end

    test "the type default wins over the alphabetical fallback" do
      # "aaa" sorts first, so the fallback would pick it.
      _alphabetically_first = library_path_fixture(%{type: "movies", path: "/tmp/aaa-movies"})
      default = library_path_fixture(%{type: "movies", path: "/tmp/zzz-movies"})
      {:ok, _} = Settings.set_default_library(default, :movies)

      assert {:ok, resolved, :type_default} = TargetResolver.resolve(movie())
      assert resolved.id == default.id
    end

    test "falls back to the alphabetically first compatible library" do
      first = library_path_fixture(%{type: "movies", path: "/tmp/aaa-movies"})
      _second = library_path_fixture(%{type: "movies", path: "/tmp/zzz-movies"})

      assert {:ok, resolved, :first_compatible} = TargetResolver.resolve(movie())
      assert resolved.id == first.id
    end
  end

  describe "resolve/2 candidate validation" do
    test "falls through a disabled explicit target" do
      disabled = library_path_fixture(%{type: "movies", path: "/tmp/zzz-disabled"})
      fallback = library_path_fixture(%{type: "movies", path: "/tmp/aaa-fallback"})
      item = movie(%{library_path_id: disabled.id})
      {:ok, _} = Settings.update_library_path(disabled, %{disabled: true})

      assert {:ok, resolved, :first_compatible} = TargetResolver.resolve(item)
      assert resolved.id == fallback.id
    end

    test "falls through an explicit target of the wrong type" do
      wrong_type = library_path_fixture(%{type: "series", path: "/tmp/zzz-series"})
      fallback = library_path_fixture(%{type: "movies", path: "/tmp/aaa-movies"})
      item = movie(%{library_path_id: wrong_type.id})

      assert {:ok, resolved, :first_compatible} = TargetResolver.resolve(item)
      assert resolved.id == fallback.id
    end

    test "honours an explicit target that is unmonitored" do
      unmonitored = library_path_fixture(%{type: "movies", path: "/tmp/zzz-unmonitored"})
      _fallback = library_path_fixture(%{type: "movies", path: "/tmp/aaa-movies"})
      item = movie(%{library_path_id: unmonitored.id})
      {:ok, unmonitored} = Settings.update_library_path(unmonitored, %{monitored: false})

      assert {:ok, resolved, :explicit} = TargetResolver.resolve(item)
      assert resolved.id == unmonitored.id
    end

    test "does not infer an unmonitored library from existing files" do
      unmonitored = library_path_fixture(%{type: "movies", path: "/tmp/zzz-unmonitored"})
      fallback = library_path_fixture(%{type: "movies", path: "/tmp/aaa-movies"})
      item = movie()
      file_in(item, unmonitored, "A Movie (2024)/a.mkv")
      {:ok, _} = Settings.update_library_path(unmonitored, %{monitored: false})

      assert {:ok, resolved, :first_compatible} = TargetResolver.resolve(item)
      assert resolved.id == fallback.id
    end

    test "returns an error when no compatible library exists" do
      _series_only = library_path_fixture(%{type: "series"})

      assert {:error, :no_compatible_library} = TargetResolver.resolve(movie())
    end
  end

  describe "resolve/2 existing-files tie-breaking" do
    test "picks the library holding the most files" do
      majority = library_path_fixture(%{type: "movies", path: "/tmp/zzz-majority"})
      minority = library_path_fixture(%{type: "movies", path: "/tmp/aaa-minority"})
      item = movie()

      file_in(item, majority, "A Movie (2024)/a.mkv")
      file_in(item, majority, "A Movie (2024)/b.mkv")
      file_in(item, minority, "A Movie (2024)/c.mkv")

      assert {:ok, resolved, :existing_files} = TargetResolver.resolve(item)
      assert resolved.id == majority.id
    end

    test "ignores trashed files" do
      trashed_lib = library_path_fixture(%{type: "movies", path: "/tmp/zzz-trashed"})
      live_lib = library_path_fixture(%{type: "movies", path: "/tmp/aaa-live"})
      item = movie()

      trashed = file_in(item, trashed_lib, "A Movie (2024)/old.mkv")
      file_in(item, live_lib, "A Movie (2024)/new.mkv")

      {:ok, _} =
        trashed
        |> Ecto.Changeset.change(trashed_at: DateTime.utc_now() |> DateTime.truncate(:second))
        |> Mydia.Repo.update()

      assert {:ok, resolved, :existing_files} = TargetResolver.resolve(item)
      assert resolved.id == live_lib.id
    end
  end

  describe "resolve/2 for TV" do
    test "resolves a show into a series library" do
      _movies = library_path_fixture(%{type: "movies", path: "/tmp/aaa-movies"})
      series = library_path_fixture(%{type: "series", path: "/tmp/zzz-series"})

      show = media_item_fixture(%{type: "tv_show", title: "A Show"})

      assert {:ok, resolved, :first_compatible} = TargetResolver.resolve(show)
      assert resolved.id == series.id
    end

    test "a mixed library serves both kinds" do
      mixed = library_path_fixture(%{type: "mixed"})

      assert {:ok, m, :first_compatible} = TargetResolver.resolve(movie())
      assert m.id == mixed.id

      show = media_item_fixture(%{type: "tv_show", title: "A Show"})
      assert {:ok, s, :first_compatible} = TargetResolver.resolve(show)
      assert s.id == mixed.id
    end
  end
end
