defmodule Mydia.Library.RescanScanFailureTest do
  use Mydia.DataCase

  import Ecto.Query, only: [from: 2]
  import Mydia.SettingsFixtures

  alias Mydia.Library
  alias Mydia.Library.MediaFile
  alias Mydia.MediaFixtures

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "mydia_rescan_failure_#{System.unique_integer([:positive])}")

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

  test "a base directory that no longer exists fails instead of emptying the item", %{
    tmp: tmp,
    library_path: lib
  } do
    # A renamed folder, or an unmounted share, used to reach the
    # {:error, :not_found} branch, which trashed every row for the item and
    # physically moved whichever files were still readable: #653.
    movie = MediaFixtures.media_item_fixture(%{type: "movie"})

    add_file(tmp, lib, movie, "Harrow Bay (2011)/Harrow.Bay.2011.1080p.mkv")
    add_file(tmp, lib, movie, "Harrow Bay (2011)/Harrow.Bay.2011.2160p.mkv")

    File.rename!(Path.join(tmp, "Harrow Bay (2011)"), Path.join(tmp, "Harrow Bay (2011) renamed"))

    assert {:error, :scan_failed} = Library.rescan_movie(movie.id)

    assert active_count(movie) == 2

    assert File.exists?(Path.join(tmp, "Harrow Bay (2011) renamed/Harrow.Bay.2011.1080p.mkv"))
  end

  test "entries the scanner cannot read are reported rather than swallowed", %{
    tmp: tmp,
    library_path: lib
  } do
    movie = MediaFixtures.media_item_fixture(%{type: "movie"})

    add_file(tmp, lib, movie, "Pale Orchard (2018)/Pale.Orchard.2018.1080p.mkv")

    # A dangling symlink makes Scanner.process_entry/6 record a
    # :symlink_resolution_error. The re-scan used to drop scan_result.errors on
    # the floor and report a clean sweep.
    File.ln_s!(
      "/nonexistent/Pale.Orchard.2018.2160p.mkv",
      Path.join(tmp, "Pale Orchard (2018)/Pale.Orchard.2018.2160p.mkv")
    )

    assert {:ok, result} = Library.rescan_movie(movie.id)

    assert result.deleted_files == 0
    assert [%{type: :symlink_resolution_error}] = result.scan_errors
    assert active_count(movie) == 1
  end
end
