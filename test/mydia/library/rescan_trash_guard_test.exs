defmodule Mydia.Library.RescanTrashGuardTest do
  use Mydia.DataCase

  import Ecto.Query, only: [from: 2]
  import Mydia.SettingsFixtures

  alias Mydia.Library
  alias Mydia.Library.MediaFile
  alias Mydia.MediaFixtures

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "mydia_rescan_guard_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    %{tmp: tmp, library_path: library_path_fixture(%{path: tmp, type: "movies"})}
  end

  defp add_file(tmp, lib, movie, relative_path) do
    absolute = Path.join(tmp, relative_path)
    File.mkdir_p!(Path.dirname(absolute))
    contents = "contents of #{relative_path}"
    File.write!(absolute, contents)

    {:ok, media_file} =
      Library.create_media_file(%{
        relative_path: relative_path,
        library_path_id: lib.id,
        media_item_id: movie.id,
        size: byte_size(contents)
      })

    media_file
  end

  defp active_count(movie) do
    Repo.one(
      from(f in MediaFile,
        where: f.media_item_id == ^movie.id and is_nil(f.trashed_at),
        select: count(f.id)
      )
    )
  end

  test "does not trash a row whose file is on disk outside the scanned directory", %{
    tmp: tmp,
    library_path: lib
  } do
    # The re-scan picks one base directory by voting on Path.dirname across
    # the item's rows, so the two rows under "Silver Harbour (2019)" win and
    # the third directory is never scanned. Before the guard, that third row
    # was classified missing and TrashStore moved its bytes out of the
    # library: #653.
    movie = MediaFixtures.media_item_fixture(%{type: "movie"})

    relative_paths = [
      "Silver Harbour (2019)/Silver.Harbour.2019.1080p.mkv",
      "Silver Harbour (2019)/Silver.Harbour.2019.2160p.mkv",
      "Silver Harbour (2019) [dupe]/Silver.Harbour.2019.1080p.mkv"
    ]

    for relative_path <- relative_paths, do: add_file(tmp, lib, movie, relative_path)

    assert {:ok, result} = Library.rescan_movie(movie.id)
    assert result.deleted_files == 0

    for relative_path <- relative_paths do
      assert File.exists?(Path.join(tmp, relative_path)),
             "#{relative_path} was moved off disk by the re-scan"
    end

    assert active_count(movie) == 3
  end

  test "still trashes a row whose file is genuinely gone", %{tmp: tmp, library_path: lib} do
    movie = MediaFixtures.media_item_fixture(%{type: "movie"})

    kept = "Cinder Lantern (2014)/Cinder.Lantern.2014.1080p.mkv"
    removed = "Cinder Lantern (2014)/Cinder.Lantern.2014.720p.mkv"

    add_file(tmp, lib, movie, kept)
    removed_file = add_file(tmp, lib, movie, removed)

    File.rm!(Path.join(tmp, removed))

    assert {:ok, result} = Library.rescan_movie(movie.id)
    assert result.deleted_files == 1

    assert Repo.reload!(removed_file).trashed_at
    assert active_count(movie) == 1
    assert File.exists?(Path.join(tmp, kept))
  end
end
