defmodule MetadataRelay.SubDL.FileIdTest do
  use ExUnit.Case, async: true

  alias MetadataRelay.SubDL.FileId

  test "round-trips an archive path" do
    id = FileId.encode("/subtitle/3602674-8520054.zip")

    assert {:ok, "/subtitle/3602674-8520054.zip"} = FileId.decode(id)
  end

  # SubDL echoes the caller's API key back inside the url field. If that
  # survived into the id, every client would receive the relay's key.
  test "strips the api_key query SubDL appends to the url" do
    id = FileId.encode("/subtitle/3602674-8520054.zip?api_key=subdl_secret_value")

    assert {:ok, "/subtitle/3602674-8520054.zip"} = FileId.decode(id)
    refute Base.url_decode64!(id, padding: false) =~ "subdl_secret_value"
  end

  test "rejects ids that decode to somewhere other than a SubDL archive" do
    for path <- [
          "https://evil.example.com/payload.zip",
          "//evil.example.com/payload.zip",
          "/subtitle/../../etc/passwd",
          "/subtitle/foo.srt",
          "/other/foo.zip",
          "/subtitle/foo.zip/../bar"
        ] do
      id = Base.url_encode64(path, padding: false)
      assert {:error, :invalid_file_id} = FileId.decode(id), "accepted #{path}"
    end
  end

  test "rejects malformed ids" do
    assert {:error, :invalid_file_id} = FileId.decode("not!base64!")
    assert {:error, :invalid_file_id} = FileId.decode("")
    assert {:error, :invalid_file_id} = FileId.decode(12_345)
  end
end
