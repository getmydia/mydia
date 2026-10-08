defmodule Mydia.Storage.CrossBackendTest do
  use Mydia.DataCase, async: false

  @moduletag :s3
  @moduletag :tmp_dir

  alias Mydia.S3Helpers
  alias Mydia.Storage

  setup %{tmp_dir: tmp_dir} do
    S3Helpers.ensure_backend_row!()
    loc = S3Helpers.unique_location(S3Helpers.backend())
    on_exit(fn -> S3Helpers.delete_prefix!(loc) end)
    %{loc: loc, tmp_dir: tmp_dir}
  end

  test "a local file moves into S3 and back", %{loc: loc, tmp_dir: tmp_dir} do
    local = Path.join(tmp_dir, "Invented Film (2031).mkv")
    File.write!(local, :binary.copy("m", 50_000))
    {:ok, from} = Storage.at(local)
    {:ok, object} = Storage.source(loc, "Invented Film (2031)/film.mkv")

    assert :ok = Storage.move(from, object)
    refute File.exists?(local)
    assert {:ok, %{size: 50_000}} = Storage.stat(object)

    {:ok, back} = Storage.at(Path.join(tmp_dir, "back/film.mkv"))
    assert :ok = Storage.copy(object, back)
    assert File.read!(Path.join(tmp_dir, "back/film.mkv")) == :binary.copy("m", 50_000)
    assert Storage.exists?(object)
  end

  test "ls/1 and at/1 work on s3:// paths", %{loc: loc} do
    S3Helpers.put_object!(loc, "Film/film.mkv", "v")
    S3Helpers.put_object!(loc, "Film/film.en.srt", "s")

    assert {:ok, names} = Storage.ls(Path.join(loc.uri, "Film"))
    assert Enum.sort(names) == ["film.en.srt", "film.mkv"]
    assert {:ok, "s"} = Storage.read_path(Path.join(loc.uri, "Film/film.en.srt"))
  end
end
