defmodule Mydia.Library.LibraryMoveSidecarsTest do
  use Mydia.DataCase, async: false

  @moduletag :tmp_dir

  alias Mydia.Library.LibraryMove.Sidecars
  alias Mydia.Repo
  alias Mydia.Subtitles.Subtitle

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  setup %{tmp_dir: tmp} do
    lib = library_path_fixture(%{type: "movies", path: Path.join(tmp, "lib")})
    movie = media_item_fixture(%{type: "movie", title: "Quiet Orchard", year: 2020})
    %{lib: lib, movie: movie}
  end

  defp touch(lib, rel, body \\ "x") do
    path = Path.join(lib.path, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
    path
  end

  defp file(lib, movie, rel) do
    touch(lib, rel)

    %{media_item_id: movie.id, library_path_id: lib.id, relative_path: rel, size: 1}
    |> media_file_fixture()
    |> Repo.preload(:library_path, force: true)
  end

  defp insert_subtitle(file, path) do
    %Subtitle{}
    |> Subtitle.changeset(%{
      media_file_id: file.id,
      language: "en",
      provider: "test",
      subtitle_hash: "h1",
      file_path: path,
      format: "srt"
    })
    |> Repo.insert!()
  end

  test "for/1 lists a -thumb.jpg and a -thumb.PNG beside the video", %{lib: lib, movie: movie} do
    video = file(lib, movie, "Quiet Orchard/Quiet Orchard - S01E01.mkv")
    dir = Path.dirname(Path.join(lib.path, video.relative_path))
    jpg = touch(lib, "Quiet Orchard/Quiet Orchard - S01E01-thumb.jpg")
    png = touch(lib, "Quiet Orchard/Quiet Orchard - S01E01-thumb.PNG")
    nfo = touch(lib, "Quiet Orchard/Quiet Orchard - S01E01.nfo")
    touch(lib, "Quiet Orchard/poster.jpg")

    assert {:ok, found} = Sidecars.for(video)
    assert Enum.sort(found) == Enum.sort([jpg, png, nfo])
    assert Enum.all?(found, &(Path.dirname(&1) == dir))
  end

  test "for/1 never takes a longer sibling's thumb", %{lib: lib, movie: movie} do
    glass = file(lib, movie, "Glass.mkv")
    file(lib, movie, "Glass.Harbor.mkv")
    own = touch(lib, "Glass-thumb.jpg")
    other = touch(lib, "Glass.Harbor-thumb.jpg")

    assert {:ok, found} = Sidecars.for(glass)
    assert own in found
    refute other in found
  end

  test "for/1 does not list a -thumbnail.nfo", %{lib: lib, movie: movie} do
    video = file(lib, movie, "X.mkv")
    touch(lib, "X-thumbnail.nfo")

    assert {:ok, []} = Sidecars.for(video)
  end

  test "sidecar_name?/2" do
    assert Sidecars.sidecar_name?("A.en.srt", "A.mkv")
    assert Sidecars.sidecar_name?("A-thumb.jpg", "A.mkv")
    refute Sidecars.sidecar_name?("A-poster.jpg", "A.mkv")
    refute Sidecars.sidecar_name?("poster.jpg", "A.mkv")
    refute Sidecars.sidecar_name?("A.mkv", "A.mkv")
    refute Sidecars.sidecar_name?("A-thumbnail.nfo", "A.mkv")
    refute Sidecars.sidecar_name?("A-thumb.srt", "A.mkv")
    refute Sidecars.sidecar_name?("A-thumb2.jpg", "A.mkv")
  end

  test "sidecar_form?/1" do
    for name <- ["x.en.srt", "x.NFO", "x.edl", "x-thumb.JPG"] do
      assert Sidecars.sidecar_form?(name), name
    end

    for name <- ["poster.jpg", "x.mkv", "x-poster.jpg"] do
      refute Sidecars.sidecar_form?(name), name
    end
  end

  describe "move_all/5" do
    test "renames -thumb with the video root and rewrites subtitle rows", %{
      lib: lib,
      movie: movie
    } do
      video = file(lib, movie, "Old.mkv")
      thumb = touch(lib, "Old-thumb.jpg")
      srt = touch(lib, "Old.en.srt")
      row = insert_subtitle(video, srt)
      source = Path.join(lib.path, "Old.mkv")
      dest = Path.join(lib.path, "New.mkv")

      assert [] = Sidecars.move_all([thumb, srt], source, dest, video.id, lib.path)

      assert File.exists?(Path.join(lib.path, "New-thumb.jpg"))
      assert File.exists?(Path.join(lib.path, "New.en.srt"))
      refute File.exists?(thumb)
      refute File.exists?(srt)
      assert Repo.reload!(row).file_path == Path.join(lib.path, "New.en.srt")
    end

    test "leaves a sidecar whose destination exists", %{lib: lib, movie: movie} do
      video = file(lib, movie, "Old.mkv")
      srt = touch(lib, "Old.en.srt")
      touch(lib, "New.en.srt", "taken")
      row = insert_subtitle(video, srt)

      assert [^srt] =
               Sidecars.move_all(
                 [srt],
                 Path.join(lib.path, "Old.mkv"),
                 Path.join(lib.path, "New.mkv"),
                 video.id,
                 lib.path
               )

      assert File.exists?(srt)
      assert Repo.reload!(row).file_path == srt
    end
  end
end
