defmodule Mydia.Library.BulkRenameS3Test do
  use Mydia.DataCase, async: false

  @moduletag :s3

  alias Mydia.Library.BulkRename
  alias Mydia.S3Helpers

  test "a prefixed S3 library previews without being unavailable" do
    {lp, loc} = S3Helpers.library_path!("movies")
    on_exit(fn -> S3Helpers.delete_prefix!(loc) end)
    S3Helpers.put_object!(loc, "Invented Film (2031)/old.mkv", "bytes")

    assert {:ok, %{total: 0}} = BulkRename.preview(lp)
  end
end
