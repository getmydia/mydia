defmodule Mydia.Library.TrashedReasonTest do
  @moduledoc """
  Every producer of a trashed row must say why. Without a reason the trash
  page cannot answer "did the automation do the right thing", which is most of
  why the page exists.
  """
  use Mydia.DataCase, async: false

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Library
  alias Mydia.Repo

  setup do
    on_exit(fn -> Application.delete_env(:mydia, :trash_dir) end)
    :ok
  end

  defp library_with_file(tmp_dir, name) do
    root = Path.join(tmp_dir, "lib")
    File.mkdir_p!(root)
    File.write!(Path.join(root, name), "video bytes")

    library_path = library_path_fixture(%{path: root, type: "movies"})

    {:ok, media_file} =
      Library.create_scanned_media_file(%{
        relative_path: name,
        library_path_id: library_path.id,
        media_item_id: media_item_fixture(%{type: "movie"}).id,
        size: byte_size("video bytes")
      })

    Repo.preload(media_file, :library_path)
  end

  @tag :tmp_dir
  test "trash_media_file/2 stamps the reason it was given", %{tmp_dir: tmp_dir} do
    file = library_with_file(tmp_dir, "vermilion.mkv")

    assert {:ok, trashed} = Library.trash_media_file(file, reason: :pruned)
    assert trashed.trashed_reason == :pruned
    assert Repo.reload(trashed).trashed_reason == :pruned
  end

  @tag :tmp_dir
  test "trash_media_file/2 leaves the reason nil when none is given", %{tmp_dir: tmp_dir} do
    file = library_with_file(tmp_dir, "harrowgate.mkv")

    assert {:ok, trashed} = Library.trash_media_file(file)
    assert is_nil(trashed.trashed_reason)
  end

  @tag :tmp_dir
  test "restore clears the reason with trashed_at", %{tmp_dir: tmp_dir} do
    file = library_with_file(tmp_dir, "saltcarto.mkv")

    {:ok, trashed} = Library.trash_media_file(file, reason: :manual)
    assert {:ok, restored} = Library.restore_media_file(trashed)

    assert is_nil(restored.trashed_at)
    assert is_nil(restored.trashed_reason)
  end

  describe "producers" do
    @tag :tmp_dir
    test "a scan trashes a vanished file as :missing", %{tmp_dir: tmp_dir} do
      file = library_with_file(tmp_dir, "vanishing.mkv")
      File.rm!(Mydia.Library.MediaFile.absolute_path(file))

      {:ok, _} = Mydia.Jobs.LibraryScanner.scan_library_path(file.library_path)

      assert Repo.reload(file).trashed_reason == :missing
    end

    # rescan_movie/1 is one of the three re-scan reconciliation paths
    # (series, season, movie) that trash a row the directory diff calls
    # missing. Movies need no TMDB episode refresh, which makes rescan_movie
    # the one reachable directly without stubbing metadata-relay.
    @tag :tmp_dir
    test "a movie re-scan trashes a vanished file as :missing", %{tmp_dir: tmp_dir} do
      root = Path.join(tmp_dir, "lib")
      File.mkdir_p!(root)
      library_path = library_path_fixture(%{path: root, type: "movies"})
      movie = media_item_fixture(%{type: "movie"})

      kept = "Amberfall (2013)/Amberfall.2013.1080p.mkv"
      removed = "Amberfall (2013)/Amberfall.2013.720p.mkv"

      for relative_path <- [kept, removed] do
        absolute = Path.join(root, relative_path)
        File.mkdir_p!(Path.dirname(absolute))
        File.write!(absolute, "video bytes")

        {:ok, _} =
          Library.create_media_file(%{
            relative_path: relative_path,
            library_path_id: library_path.id,
            media_item_id: movie.id,
            size: byte_size("video bytes")
          })
      end

      removed_file =
        Repo.get_by!(Mydia.Library.MediaFile, media_item_id: movie.id, relative_path: removed)

      File.rm!(Path.join(root, removed))

      assert {:ok, result} = Library.rescan_movie(movie.id)
      assert result.deleted_files == 1

      assert Repo.reload(removed_file).trashed_reason == :missing
    end
  end
end
