defmodule Mydia.Library.SidecarCleanupTest do
  use Mydia.DataCase, async: false

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Library.{SidecarCleanup, TrashStore}
  alias Mydia.Subtitles.Subtitle

  @moduletag :tmp_dir

  @show "Quiet Orchard (2020)"
  @season "Season 1"

  setup %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "lib")
    trash = Path.join(tmp_dir, "trash")
    File.mkdir_p!(root)

    previous = Application.get_env(:mydia, :trash_dir)
    Application.put_env(:mydia, :trash_dir, trash)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:mydia, :trash_dir, previous),
        else: Application.delete_env(:mydia, :trash_dir)
    end)

    lp = library_path_fixture(%{path: root, type: "mixed"})
    %{lp: lp, root: root, trash: trash}
  end

  defp touch(root, rel, content \\ "x") do
    path = Path.join(root, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    path
  end

  defp season_rel(name), do: Path.join([@show, @season, name])

  defp listed(lp) do
    {:ok, %{folders: folders}} = SidecarCleanup.preview(lp)
    folders |> Enum.flat_map(&elem(&1, 1)) |> Enum.map(&Path.basename/1) |> Enum.sort()
  end

  test "an nfo and thumb whose video is gone are orphans", %{lp: lp, root: root} do
    touch(root, season_rel("Quiet Orchard - S01E01 - Pilot.mkv"))
    nfo = touch(root, season_rel("old.name.S01E01.nfo"))
    thumb = touch(root, season_rel("old.name.S01E01-thumb.jpg"))

    assert {:ok, %{folders: [{dir, paths}], count: 2, bytes: 2, destination: dest}} =
             SidecarCleanup.preview(lp)

    assert dir == Path.dirname(nfo)
    assert Enum.sort(paths) == Enum.sort([nfo, thumb])
    assert dest == TrashStore.root_for_library(lp)
  end

  test "artwork and item nfos are never orphans", %{lp: lp, root: root} do
    for name <- ["tvshow.nfo", "poster.jpg", "season01-poster.jpg", "fanart.jpg", "season.nfo"] do
      touch(root, Path.join(@show, name))
    end

    assert listed(lp) == []
  end

  test "sidecars of a video no row knows are kept", %{lp: lp, root: root} do
    touch(root, season_rel("Unscanned.mkv"))
    touch(root, season_rel("Unscanned.en.srt"))

    assert listed(lp) == []
  end

  test "a tracked subtitle is kept", %{lp: lp, root: root} do
    item = media_item_fixture(%{type: "movie", title: "Paper Comet", year: 2019})

    file =
      media_file_fixture(%{
        media_item_id: item.id,
        library_path_id: lp.id,
        relative_path: "elsewhere.mkv"
      })

    touch(root, season_rel("Quiet Orchard - S01E01 - Pilot.mkv"))
    path = touch(root, season_rel("old.name.S01E01.en.srt"))
    other = touch(root, season_rel("old.name.S01E02.en.srt"))

    Repo.insert!(%Subtitle{
      media_file_id: file.id,
      language: "en",
      provider: "test",
      subtitle_hash: "abc123",
      file_path: path,
      format: "srt"
    })

    assert listed(lp) == ["old.name.S01E02.en.srt"]
    refute SidecarCleanup.orphan?(path, lp)
    assert SidecarCleanup.orphan?(other, lp)
  end

  test "a longer sibling's sidecar is not taken as orphan", %{lp: lp, root: root} do
    touch(root, season_rel("Glass.Harbor.mkv"))
    touch(root, season_rel("Glass.Harbor-thumb.jpg"))

    assert listed(lp) == []
  end

  test "orphan? is false for missing files, directories and paths outside the library",
       %{lp: lp, root: root, tmp_dir: tmp_dir} do
    refute SidecarCleanup.orphan?(Path.join(root, "missing.nfo"), lp)

    File.mkdir_p!(Path.join(root, "folder.nfo.d/x.nfo"))
    refute SidecarCleanup.orphan?(Path.join(root, "folder.nfo.d/x.nfo"), lp)

    outside = touch(tmp_dir, "outside/old.nfo")
    refute SidecarCleanup.orphan?(outside, lp)
  end

  test "a trash directory inside the library is never walked or touched", %{lp: lp, root: root} do
    kept = touch(root, Path.join(TrashStore.dir_name(), "x/old.nfo"))

    assert listed(lp) == []
    refute SidecarCleanup.orphan?(kept, lp)
    assert {:ok, %{moved: 0, kept: 1, container: nil}} = SidecarCleanup.run(lp, [kept])
    assert File.exists?(kept)
  end

  test "run re-checks: a video added after preview protects its sidecars", %{lp: lp, root: root} do
    touch(root, season_rel("Quiet Orchard - S01E01 - Pilot.mkv"))
    touch(root, season_rel("old.name.S01E01.nfo"))
    touch(root, season_rel("old.name.S01E01-thumb.jpg"))

    {:ok, %{folders: [{_dir, paths}]}} = SidecarCleanup.preview(lp)
    touch(root, season_rel("old.name.S01E01.mkv"))

    assert {:ok, %{kept: 2, moved: 0, container: nil}} = SidecarCleanup.run(lp, paths)
    assert Enum.all?(paths, &File.exists?/1)
  end

  test "run moves orphans under sidecar-cleanup-<ts> with relative paths",
       %{lp: lp, root: root, trash: trash} do
    touch(root, season_rel("Quiet Orchard - S01E01 - Pilot.mkv"))
    nfo = touch(root, season_rel("old.name.S01E01.nfo"), "nfo-body")
    {:ok, %{folders: [{_dir, paths}]}} = SidecarCleanup.preview(lp)

    assert {:ok, %{moved: 1, kept: 0, container: container}} =
             SidecarCleanup.run(lp, paths)

    refute File.exists?(nfo)
    assert Path.dirname(container) == trash
    assert Path.basename(container) =~ ~r/^sidecar-cleanup-\d{8}T\d{6}Z$/

    assert File.read!(Path.join([container, @show, @season, "old.name.S01E01.nfo"])) ==
             "nfo-body"
  end

  test "run only touches paths passed in, even if other orphans exist", %{lp: lp, root: root} do
    touch(root, season_rel("Quiet Orchard - S01E01 - Pilot.mkv"))
    a = touch(root, season_rel("a.name.S01E01.nfo"))
    b = touch(root, season_rel("b.name.S01E02.nfo"))

    assert {:ok, %{moved: 1}} = SidecarCleanup.run(lp, [a])
    refute File.exists?(a)
    assert File.exists?(b)
  end

  test "a Subs folder beside a movie's video is not an orphan", %{lp: lp, root: root} do
    touch(root, "Paper Comet (2019)/Paper Comet.mkv")
    touch(root, "Paper Comet (2019)/Subs/English.srt")

    assert listed(lp) == []
  end

  test "an iso, strm or VIDEO_TS file protects its sidecars", %{lp: lp, root: root} do
    touch(root, "Disc/Other.mkv")
    touch(root, "Disc/Film.iso")
    touch(root, "Disc/Film.nfo")
    touch(root, "Disc/Film-thumb.jpg")
    touch(root, "Disc/Stream.strm")
    touch(root, "Disc/Stream.nfo")
    touch(root, "Disc/VIDEO_TS.IFO")
    touch(root, "Disc/VIDEO_TS.nfo")

    assert listed(lp) == []
  end

  test "roots are compared case-insensitively", %{lp: lp, root: root} do
    touch(root, season_rel("Glass Harbor.mkv"))
    touch(root, season_rel("glass harbor.en.srt"))

    assert listed(lp) == []
  end

  test "a directory without a video yields no orphans", %{lp: lp, root: root} do
    nfo = touch(root, "Loose/old.name.nfo")

    assert listed(lp) == []
    refute SidecarCleanup.orphan?(nfo, lp)
  end

  test "TrashStore.audit reports the container as orphaned", %{lp: lp, root: root} do
    touch(root, season_rel("Quiet Orchard - S01E01 - Pilot.mkv"))
    nfo = touch(root, season_rel("old.name.S01E01.nfo"))
    {:ok, %{container: container}} = SidecarCleanup.run(lp, [nfo])

    assert Enum.any?(TrashStore.audit().orphaned, &(&1.path == container))
  end

  test "an s3 library is s3_unsupported" do
    lp = %Mydia.Settings.LibraryPath{path: "s3://bucket/media", type: :series}

    assert {:error, :s3_unsupported} = SidecarCleanup.preview(lp)
    assert {:error, :s3_unsupported} = SidecarCleanup.run(lp, ["s3://bucket/media/a.nfo"])
    refute SidecarCleanup.orphan?("s3://bucket/media/a.nfo", lp)
  end

  test "a missing library root is unavailable", %{lp: lp, root: root} do
    File.rm_rf!(root)
    assert {:error, :library_unavailable} = SidecarCleanup.preview(lp)
  end
end
