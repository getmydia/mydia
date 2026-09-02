defmodule Mydia.Library.OriginDownloadTest do
  use Mydia.DataCase, async: true

  alias Mydia.Library
  alias Mydia.Library.MediaFile
  alias Mydia.Library.Structs.FileMetadata
  alias Mydia.Repo

  import Mydia.Factory

  test "resolves the download a file was imported from" do
    download = insert(:download)

    file =
      insert(:media_file, %{
        metadata: %FileMetadata{extra: %{"imported_from_download_id" => download.id}}
      })

    assert %{id: id} = Library.origin_download(file)
    assert id == download.id
  end

  test "returns nil for a file with populated, but empty, metadata" do
    file = insert(:media_file, %{metadata: %FileMetadata{extra: %{}}})
    assert Library.origin_download(file) == nil
  end

  test "returns nil for a freshly scanned file whose metadata column is genuinely NULL" do
    # A freshly scanned file's creation attrs never include a :metadata key at
    # all -- see Mydia.Library.create_media_files_for_series/3 (lib/mydia/library.ex),
    # which calls create_scanned_media_file/1 with an attrs map that has no
    # :metadata entry whatsoever. Verified empirically (via a raw
    # `SELECT metadata FROM media_files` against a file created through this
    # exact real code path, including once with an explicit `metadata: nil`
    # forced through the changeset's cast/3) that Ecto's cast/dump/load
    # pipeline short-circuits `nil` for this field universally: the column is
    # stored as literal SQL NULL and reloads as literal `nil`, never as
    # FileMetadata.empty(). FileMetadataType's own nil-handling clauses in
    # cast/1, load/1 and dump/1 (lib/mydia/library/file_metadata_type.ex) are
    # therefore dead code from Ecto's perspective -- Ecto never dispatches to
    # them for a nil value. This is consequently the default, common shape of
    # any not-yet-analyzed scanner file, not a corner case, and it lands on
    # origin_download/1's second, unguarded clause rather than the first.
    library_path = insert(:library_path)
    media_item = insert(:media_item)

    {:ok, file} =
      Library.create_scanned_media_file(%{
        relative_path: "movie.mkv",
        library_path_id: library_path.id,
        size: 1_000,
        media_item_id: media_item.id
      })

    reloaded = Repo.get!(MediaFile, file.id)

    assert reloaded.metadata == nil
    assert Library.origin_download(reloaded) == nil
  end

  test "returns nil when the download row has been cleared" do
    download = insert(:download)

    file =
      insert(:media_file, %{
        metadata: %FileMetadata{extra: %{"imported_from_download_id" => download.id}}
      })

    Mydia.Repo.delete!(download)

    assert Library.origin_download(file) == nil
  end
end
