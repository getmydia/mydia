defmodule Mydia.Library.RescanRelinkTest do
  use Mydia.DataCase

  import Ecto.Query, only: [from: 2]
  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Library
  alias Mydia.Library.MediaFile
  alias Mydia.Media

  setup do
    base =
      Path.join(System.tmp_dir!(), "mydia_rescan_relink_#{System.unique_integer([:positive])}")

    dir_a = Path.join(base, "a")
    dir_b = Path.join(base, "b")
    File.mkdir_p!(dir_a)
    File.mkdir_p!(dir_b)
    on_exit(fn -> File.rm_rf(base) end)

    %{
      dir_a: dir_a,
      dir_b: dir_b,
      lib_a: library_path_fixture(%{path: dir_a, type: "mixed"}),
      lib_b: library_path_fixture(%{path: dir_b, type: "mixed"})
    }
  end

  defp write(root, relative, contents \\ "0123456789") do
    absolute = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(absolute))
    File.write!(absolute, contents)
    relative
  end

  defp movie_row(lib, movie, relative, size \\ 10) do
    {:ok, row} =
      Library.create_media_file(%{
        relative_path: relative,
        library_path_id: lib.id,
        media_item_id: movie.id,
        size: size
      })

    row
  end

  defp active_count(movie) do
    Repo.one(
      from(f in MediaFile,
        where: f.media_item_id == ^movie.id and is_nil(f.trashed_at),
        select: count(f.id)
      )
    )
  end

  describe "movies" do
    test "a vanished directory does not stop the scan of one that exists", ctx do
      movie = media_item_fixture(%{type: "movie"})

      movie_row(ctx.lib_a, movie, "Quiet Meridian (2001)/f.mkv")
      write(ctx.dir_b, "Quiet Meridian (2001)/f2.mkv")
      movie_row(ctx.lib_b, movie, "Quiet Meridian (2001)/f2.mkv")

      assert {:ok, result} = Library.rescan_movie(movie.id)
      assert result.new_files == 0
    end

    test "returns :no_files_on_disk and leaves rows alone when no directory exists", ctx do
      movie = media_item_fixture(%{type: "movie"})
      row = movie_row(ctx.lib_a, movie, "Quiet Meridian (2001)/f.mkv")

      assert {:error, :no_files_on_disk} = Library.rescan_movie(movie.id)

      assert is_nil(Repo.reload!(row).trashed_at)
      assert active_count(movie) == 1
    end

    test "relinks a file renamed in place", ctx do
      movie = media_item_fixture(%{type: "movie"})
      write(ctx.dir_a, "Quiet Meridian (2001)/a.mkv")
      row = movie_row(ctx.lib_a, movie, "Quiet Meridian (2001)/a.mkv")

      File.rename!(
        Path.join(ctx.dir_a, "Quiet Meridian (2001)/a.mkv"),
        Path.join(ctx.dir_a, "Quiet Meridian (2001)/b.mkv")
      )

      assert {:ok, result} = Library.rescan_movie(movie.id)
      assert result.new_files == 0
      assert result.deleted_files == 0

      reloaded = Repo.reload!(row)
      assert reloaded.relative_path == "Quiet Meridian (2001)/b.mkv"
      assert is_nil(reloaded.trashed_at)
      assert active_count(movie) == 1
    end
  end

  describe "series" do
    setup ctx do
      lib = ctx.lib_a

      show =
        media_item_fixture(%{type: "tv_show", title: "Amber Tide", year: 2019, tvdb_id: 900_002})

      Media.stamp_seasons_refreshed(show)
      ep = episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 1})
      Map.merge(ctx, %{series_lib: lib, show: show, episode: ep})
    end

    defp series_row(ctx, lib, relative) do
      {:ok, row} =
        Library.create_media_file(%{
          relative_path: relative,
          library_path_id: lib.id,
          episode_id: ctx.episode.id,
          size: 10
        })

      row
    end

    test "a vanished series folder does not stop the scan of one that exists", ctx do
      series_row(ctx, ctx.lib_a, "Amber Tide/Season 01/Amber.Tide.S01E01.mkv")
      write(ctx.dir_b, "Amber Tide/Season 01/Amber.Tide.S01E01.alt.mkv")
      series_row(ctx, ctx.lib_b, "Amber Tide/Season 01/Amber.Tide.S01E01.alt.mkv")

      assert {:ok, result} = Library.rescan_series(ctx.show.id)
      assert result.new_files == 0
    end

    test "returns :no_files_on_disk and leaves rows alone when no folder exists", ctx do
      row = series_row(ctx, ctx.lib_a, "Amber Tide/Season 01/Amber.Tide.S01E01.mkv")

      assert {:error, :no_files_on_disk} = Library.rescan_series(ctx.show.id)
      assert is_nil(Repo.reload!(row).trashed_at)
    end

    test "relinks an episode file renamed in its season folder", ctx do
      old = "Amber Tide/Season 01/Amber.Tide.S01E01.720p.mkv"
      write(ctx.dir_a, old)
      row = series_row(ctx, ctx.lib_a, old)

      new = "Amber Tide/Season 01/Amber.Tide.S01E01.1080p.mkv"
      File.rename!(Path.join(ctx.dir_a, old), Path.join(ctx.dir_a, new))

      assert {:ok, result} = Library.rescan_series(ctx.show.id)
      assert result.new_files == 0
      assert result.deleted_files == 0

      reloaded = Repo.reload!(row)
      assert reloaded.relative_path == new
      assert is_nil(reloaded.trashed_at)
      assert reloaded.episode_id == ctx.episode.id
    end
  end
end
