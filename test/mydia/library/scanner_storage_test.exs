defmodule Mydia.Library.ScannerStorageTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.Scanner
  alias Mydia.Settings.StorageBackend
  alias Mydia.Storage.{Error, Location}

  setup do
    bypass = Bypass.open()

    b = %StorageBackend{
      name: "m",
      endpoint: "http://localhost:#{bypass.port}",
      region: "us-east-1",
      bucket: "lib",
      access_key_id: "k",
      secret_access_key: "s",
      path_style: true
    }

    %{bypass: bypass, location: Location.s3(b, "movies/", "s3://m/movies")}
  end

  test "lists video objects, skipping other extensions and the trash", %{
    bypass: bypass,
    location: loc
  } do
    trash = Mydia.Library.TrashStore.dir_name()

    Bypass.expect(bypass, "GET", "/lib", fn conn ->
      Plug.Conn.resp(
        conn,
        200,
        list_xml([
          "movies/Invented Film (2031)/film.mkv",
          "movies/Invented Film (2031)/poster.jpg",
          "movies/#{trash}/old.mkv"
        ])
      )
    end)

    assert {:ok, %{files: [file], total_count: 1}} = Scanner.scan_location(loc)
    assert file.path == "s3://m/movies/Invented Film (2031)/film.mkv"
    assert file.extension == ".mkv"
    assert Path.relative_to(file.path, loc.uri) == "Invented Film (2031)/film.mkv"
  end

  test "relativizing against a library path with or without a trailing slash" do
    path = "s3://m/movies/Invented Film (2031)/film.mkv"

    for base <- ["s3://m/movies", "s3://m/movies/"] do
      assert Path.relative_to(path, base) == "Invented Film (2031)/film.mkv"
    end
  end

  test "an unreachable backend is an error, never an empty scan", %{
    bypass: bypass,
    location: loc
  } do
    Bypass.down(bypass)
    assert {:error, %Error{kind: :unreachable}} = Scanner.scan_location(loc)
  end

  defp list_xml(keys) do
    contents =
      Enum.map_join(keys, fn k ->
        "<Contents><Key>#{k}</Key><Size>3</Size><LastModified>2031-10-01T10:00:00.000Z</LastModified></Contents>"
      end)

    "<ListBucketResult><IsTruncated>false</IsTruncated>#{contents}</ListBucketResult>"
  end
end
