defmodule Mydia.Jobs.MediaRematchTest do
  @moduledoc """
  Tests for the post-import re-match job: it moves an already-imported file to
  the corrected location, relinks the MediaFile (parent-flip), adopts any
  scanner-created duplicate at the destination, leaves the old item file-less,
  and is idempotent on retry.
  """
  use Mydia.DataCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  @moduletag :tmp_dir

  alias Mydia.Jobs.MediaRematch
  alias Mydia.Library
  alias Mydia.Library.MediaFile
  alias Mydia.Repo

  import Mydia.MediaFixtures
  import Mydia.DownloadsFixtures
  import Mydia.SettingsFixtures

  defp movies_library(tmp) do
    path = Path.join(tmp, "movies")
    File.mkdir_p!(path)

    library_path_fixture(%{
      type: "movies",
      path: path,
      monitored: true,
      auto_organize: false,
      auto_rename: false
    })
  end

  defp series_library(tmp) do
    path = Path.join(tmp, "series")
    File.mkdir_p!(path)

    library_path_fixture(%{
      type: "series",
      path: path,
      monitored: true,
      auto_organize: false,
      auto_rename: false
    })
  end

  defp write_source(library, relative_path, contents) do
    abs = Path.join(library.path, relative_path)
    File.mkdir_p!(Path.dirname(abs))
    File.write!(abs, contents)
    {abs, byte_size(contents)}
  end

  describe "movie re-match" do
    test "moves the file, relinks to the new movie, and leaves the old item file-less", %{
      tmp_dir: tmp
    } do
      library = movies_library(tmp)
      old_movie = media_item_fixture(%{type: "movie", title: "Wrong Movie", year: 2020})
      new_movie = media_item_fixture(%{type: "movie", title: "Right Movie", year: 2021})

      {_abs, size} = write_source(library, "Wrong Movie (2020)/movie.mkv", "video-bytes")

      # download already corrected to the new movie (as Queue.rematch_imported_download does)
      download =
        download_fixture(%{
          media_item_id: new_movie.id,
          imported_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      {:ok, media_file} =
        Library.create_media_file(%{
          relative_path: "Wrong Movie (2020)/movie.mkv",
          library_path_id: library.id,
          media_item_id: old_movie.id,
          size: size,
          metadata: %{"imported_from_download_id" => download.id}
        })

      assert {:ok, :rematched} =
               perform_job(MediaRematch, %{"download_id" => download.id})

      reloaded = Repo.get(MediaFile, media_file.id)
      assert reloaded.media_item_id == new_movie.id
      assert reloaded.relative_path == "Right Movie (2021)/movie.mkv"

      assert File.exists?(Path.join(library.path, "Right Movie (2021)/movie.mkv"))
      refute File.exists?(Path.join(library.path, "Wrong Movie (2020)/movie.mkv"))

      # Old item is left in place but now has no files (no destructive cleanup).
      assert Repo.get(Mydia.Media.MediaItem, old_movie.id)
      assert Library.list_media_files(media_item_id: old_movie.id) == []
    end
  end

  describe "episode re-match (parent-flip)" do
    test "moves the file into the correct season folder and flips the parent", %{tmp_dir: tmp} do
      library = series_library(tmp)
      show = media_item_fixture(%{type: "tv_show", title: "My Show"})
      old_ep = episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 1})
      new_ep = episode_fixture(%{media_item_id: show.id, season_number: 2, episode_number: 5})

      {_abs, size} = write_source(library, "Wrong/ep.mkv", "ep-bytes")

      download =
        download_fixture(%{
          media_item_id: show.id,
          episode_id: new_ep.id,
          imported_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      {:ok, media_file} =
        Library.create_media_file(%{
          relative_path: "Wrong/ep.mkv",
          library_path_id: library.id,
          episode_id: old_ep.id,
          size: size,
          metadata: %{"imported_from_download_id" => download.id}
        })

      assert {:ok, :rematched} = perform_job(MediaRematch, %{"download_id" => download.id})

      reloaded = Repo.get(MediaFile, media_file.id)
      assert reloaded.episode_id == new_ep.id
      assert is_nil(reloaded.media_item_id)
      assert reloaded.relative_path == "My Show/Season 02/ep.mkv"
      assert File.exists?(Path.join(library.path, "My Show/Season 02/ep.mkv"))
    end
  end

  describe "download deleted mid-job" do
    test "keeps the relink when the provenance stamp finds no row", %{tmp_dir: tmp} do
      # Regression for #285. The provenance stamp is an audit trail written at
      # the end of the relink transaction. If an operator clears the download
      # while the job is moving the file, that write finds no row — and rolling
      # the transaction back would throw away a correct, disk-verified relink
      # over bookkeeping. Because the row stays gone, every retry would fail the
      # same way until the job is discarded, leaving the file mis-linked for good.
      library = movies_library(tmp)
      old_movie = media_item_fixture(%{type: "movie", title: "Wrong Movie", year: 2020})
      new_movie = media_item_fixture(%{type: "movie", title: "Right Movie", year: 2021})

      {_abs, size} = write_source(library, "Wrong Movie (2020)/movie.mkv", "video-bytes")

      download =
        download_fixture(%{
          media_item_id: new_movie.id,
          imported_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      {:ok, media_file} =
        Library.create_media_file(%{
          relative_path: "Wrong Movie (2020)/movie.mkv",
          library_path_id: library.id,
          media_item_id: old_movie.id,
          size: size,
          metadata: %{"imported_from_download_id" => download.id}
        })

      # Delete the row on the job's opening read of it, which is well before the
      # relink transaction opens. The match stops before the placeholder because
      # that is adapter-specific (`?` on SQLite, `$1` on Postgres) — matching one
      # form would leave this test silently inert on the other adapter.
      handler_id = {__MODULE__, :delete_before_provenance, download.id}
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:mydia, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if self() == test_pid and metadata.source == "downloads" and
               String.contains?(metadata.query, ~s|."id" = |) do
            :telemetry.detach(handler_id)
            {:ok, _} = Mydia.Downloads.delete_download(download)
            send(test_pid, :download_deleted_mid_job)
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, :rematched} = perform_job(MediaRematch, %{"download_id" => download.id})

      # Without this the test would pass even if the delete never fired.
      assert_received :download_deleted_mid_job

      # The relink survived: parent flipped and the bytes are at the new path.
      reloaded = Repo.get(MediaFile, media_file.id)
      assert reloaded.media_item_id == new_movie.id
      assert reloaded.relative_path == "Right Movie (2021)/movie.mkv"
      assert File.exists?(Path.join(library.path, "Right Movie (2021)/movie.mkv"))
    end
  end

  describe "concurrency + idempotency" do
    test "adopts a scanner-created duplicate at the destination (no duplicate row)", %{
      tmp_dir: tmp
    } do
      library = movies_library(tmp)
      old_movie = media_item_fixture(%{type: "movie", title: "Wrong Movie", year: 2020})
      new_movie = media_item_fixture(%{type: "movie", title: "Right Movie", year: 2021})

      {_abs, size} = write_source(library, "Wrong Movie (2020)/movie.mkv", "video-bytes")

      download =
        download_fixture(%{
          media_item_id: new_movie.id,
          imported_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      {:ok, _media_file} =
        Library.create_media_file(%{
          relative_path: "Wrong Movie (2020)/movie.mkv",
          library_path_id: library.id,
          media_item_id: old_movie.id,
          size: size,
          metadata: %{"imported_from_download_id" => download.id}
        })

      # Simulate a racing scan that already created an orphan row at the dest path.
      {:ok, _orphan} =
        Library.create_scanned_media_file(%{
          relative_path: "Right Movie (2021)/movie.mkv",
          library_path_id: library.id,
          size: size
        })

      assert {:ok, :rematched} = perform_job(MediaRematch, %{"download_id" => download.id})

      rows =
        Library.list_media_files(library_path_id: library.id)
        |> Enum.filter(&(&1.relative_path == "Right Movie (2021)/movie.mkv"))

      assert length(rows) == 1
      assert hd(rows).media_item_id == new_movie.id
    end

    test "is idempotent on retry", %{tmp_dir: tmp} do
      library = movies_library(tmp)
      old_movie = media_item_fixture(%{type: "movie", title: "Wrong Movie", year: 2020})
      new_movie = media_item_fixture(%{type: "movie", title: "Right Movie", year: 2021})

      {_abs, size} = write_source(library, "Wrong Movie (2020)/movie.mkv", "video-bytes")

      download =
        download_fixture(%{
          media_item_id: new_movie.id,
          imported_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      {:ok, media_file} =
        Library.create_media_file(%{
          relative_path: "Wrong Movie (2020)/movie.mkv",
          library_path_id: library.id,
          media_item_id: old_movie.id,
          size: size,
          metadata: %{"imported_from_download_id" => download.id}
        })

      assert {:ok, :rematched} = perform_job(MediaRematch, %{"download_id" => download.id})
      # Second run: the file is already at the destination and the row is relinked.
      assert {:ok, :rematched} = perform_job(MediaRematch, %{"download_id" => download.id})

      rows = Library.list_media_files(library_path_id: library.id)
      assert length(rows) == 1
      assert Repo.get(MediaFile, media_file.id).relative_path == "Right Movie (2021)/movie.mkv"
    end
  end
end
