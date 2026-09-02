defmodule Mydia.Library.OriginDownloadTest do
  use Mydia.DataCase, async: true

  alias Mydia.Library
  alias Mydia.Library.Structs.FileMetadata

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

  test "returns nil for a scanner-discovered file" do
    file = insert(:media_file, %{metadata: %FileMetadata{extra: %{}}})
    assert Library.origin_download(file) == nil
  end

  test "returns nil when the file has no metadata" do
    file = insert(:media_file, %{metadata: nil})
    assert Library.origin_download(file) == nil
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
