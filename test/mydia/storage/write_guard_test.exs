defmodule Mydia.Storage.WriteGuardTest do
  use Mydia.DataCase, async: false

  alias Mydia.Library.FileOrganizer
  alias Mydia.Settings
  alias Mydia.Storage.Error

  # A persisted S3 backend pointing at an unreachable endpoint.
  setup do
    {:ok, _} =
      Settings.create_storage_backend(%{
        name: "m",
        endpoint: "http://localhost:1",
        region: "us-east-1",
        bucket: "lib",
        access_key_id: "k",
        secret_access_key: "s"
      })

    :ok
  end

  @tag :tmp_dir
  test "place_file into an unreachable bucket reports the outage", %{tmp_dir: tmp_dir} do
    src = Path.join(tmp_dir, "a.mkv")
    File.write!(src, "x")

    assert {:error, %Error{kind: :unreachable}} =
             FileOrganizer.place_file(src, "s3://m/movies/A/a.mkv", expected_size: 1)

    assert File.exists?(src)
  end
end
