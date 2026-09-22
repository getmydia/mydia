defmodule Mydia.Library.ItemFoldersTest do
  use Mydia.DataCase, async: true

  import Mydia.SettingsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Library
  alias Mydia.Library.ItemFolders
  alias Mydia.Library.ItemFolders.Folder
  alias Mydia.Library.MediaFile
  alias Mydia.Repo

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    root = Path.join(tmp, "lib")
    File.mkdir_p!(root)
    %{root: root, lp: library_path_fixture(%{path: root, type: "mixed"})}
  end

  # An in-memory row in production shape: relative_path plus a loaded
  # library_path, path nil. folders_for/1 reads only the struct.
  defp file(lp, rel, attrs \\ []) do
    struct!(
      %MediaFile{
        id: Ecto.UUID.generate(),
        relative_path: rel,
        library_path_id: lp.id,
        library_path: lp
      },
      attrs
    )
  end

  defp relatives(folders), do: Enum.map(folders, & &1.relative)

  describe "folders_for/1" do
    test "a movie in its own folder", %{root: root, lp: lp} do
      assert [%Folder{relative: "Harbor Lights (2011)", absolute: absolute, library_path: ^lp}] =
               ItemFolders.folders_for([
                 file(lp, "Harbor Lights (2011)/Harbor Lights (2011).mkv")
               ])

      assert absolute == Path.join(root, "Harbor Lights (2011)")
    end

    test "episodes resolve to the show folder above their season folders", %{lp: lp} do
      files = [
        file(lp, "Tin Kettle/Season 01/Tin Kettle S01E01.mkv"),
        file(lp, "Tin Kettle/Season 02/Tin Kettle S02E01.mkv")
      ]

      assert relatives(ItemFolders.folders_for(files)) == ["Tin Kettle"]
    end

    test "a file loose in the library root has no folder", %{lp: lp} do
      assert ItemFolders.folders_for([file(lp, "Loose Film.mkv")]) == []
    end

    test "a generic folder name counts as loose", %{lp: lp} do
      assert ItemFolders.folders_for([file(lp, "movies/Loose Film.mkv")]) == []
    end

    test "a redundant release folder climbs to the title folder", %{lp: lp} do
      files = [file(lp, "Harbor Lights (2011)/Harbor.Lights.2011.1080p.BluRay-GRP/hl.mkv")]

      assert relatives(ItemFolders.folders_for(files)) == ["Harbor Lights (2011)"]
    end

    test "a folder nested inside another of the item's folders merges into it", %{lp: lp} do
      files = [
        file(lp, "Harbor Lights (2011)/Harbor Lights (2011).mkv"),
        file(lp, "Harbor Lights (2011)/Bonus Reel/Commentary Cut.mkv")
      ]

      assert relatives(ItemFolders.folders_for(files)) == ["Harbor Lights (2011)"]
    end

    test "extras and trashed files contribute no folder", %{lp: lp} do
      files = [
        file(lp, "Extras Only/Featurette.mkv", extra_kind: :featurette),
        file(lp, "Trashed One/film.mkv", trashed_at: ~U[2026-09-01 00:00:00Z])
      ]

      assert ItemFolders.folders_for(files) == []
    end

    test "a folder that contains another library path is refused", %{root: root, lp: lp} do
      library_path_fixture(%{path: Path.join(root, "Collection/Inner")})

      assert ItemFolders.folders_for([file(lp, "Collection/film.mkv")]) == []
    end

    test "a file whose library path is not loaded contributes nothing", %{lp: lp} do
      unloaded = %MediaFile{
        id: Ecto.UUID.generate(),
        relative_path: "Harbor Lights (2011)/Harbor Lights (2011).mkv",
        library_path_id: lp.id
      }

      assert ItemFolders.folders_for([unloaded]) == []
    end
  end

  describe "blockers/2" do
    setup %{root: root, lp: lp} do
      item = media_item_fixture(%{type: "movie", title: "Harbor Lights"})
      dir = Path.join(root, "Harbor Lights (2011)")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "Harbor Lights (2011).mkv"), "video")

      {:ok, own} =
        Library.create_scanned_media_file(%{
          relative_path: "Harbor Lights (2011)/Harbor Lights (2011).mkv",
          library_path_id: lp.id,
          media_item_id: item.id,
          size: 5
        })

      own = Repo.preload(own, :library_path)
      [folder] = ItemFolders.folders_for([own])
      %{dir: dir, own: own, folder: folder}
    end

    test "the item's own file is not a blocker", %{own: own, folder: folder} do
      assert ItemFolders.blockers(folder, ignore: [own]) == []
    end

    test "artwork, NFOs, subtitles, text files and samples are not blockers", ctx do
      for name <- ["poster.jpg", "movie.nfo", "Harbor Lights (2011).en.srt", "release.txt"] do
        File.write!(Path.join(ctx.dir, name), "x")
      end

      File.mkdir_p!(Path.join(ctx.dir, "Sample"))
      File.write!(Path.join(ctx.dir, "Sample/harbor-sample.mkv"), "x")

      assert ItemFolders.blockers(ctx.folder, ignore: [ctx.own]) == []
    end

    test "another item's file row blocks, and is reported once", ctx do
      other = media_item_fixture(%{type: "movie", title: "Quiet Orchard"})
      File.write!(Path.join(ctx.dir, "Quiet Orchard.mkv"), "video")

      {:ok, _} =
        Library.create_scanned_media_file(%{
          relative_path: "Harbor Lights (2011)/Quiet Orchard.mkv",
          library_path_id: ctx.lp.id,
          media_item_id: other.id,
          size: 5
        })

      assert ItemFolders.blockers(ctx.folder, ignore: [ctx.own]) ==
               [{:media_file, "Harbor Lights (2011)/Quiet Orchard.mkv"}]
    end

    test "an import candidate blocks", ctx do
      File.write!(Path.join(ctx.dir, "Unsorted Reel.mkv"), "video")

      import_candidate_fixture(
        library_path_id: ctx.lp.id,
        relative_path: "Harbor Lights (2011)/Unsorted Reel.mkv"
      )

      assert ItemFolders.blockers(ctx.folder, ignore: [ctx.own]) ==
               [{:import_candidate, "Harbor Lights (2011)/Unsorted Reel.mkv"}]
    end

    test "a video on disk with no row blocks, whatever the extension's case", ctx do
      File.write!(Path.join(ctx.dir, "Stray Reel.MKV"), "video")

      assert ItemFolders.blockers(ctx.folder, ignore: [ctx.own]) ==
               [{:video, "Harbor Lights (2011)/Stray Reel.MKV"}]
    end

    test "a symlink to a directory full of videos is not followed", ctx do
      elsewhere = Path.join(ctx.tmp_dir, "elsewhere")
      File.mkdir_p!(elsewhere)
      File.write!(Path.join(elsewhere, "Quiet Orchard.mkv"), "video")
      File.ln_s!(elsewhere, Path.join(ctx.dir, "link"))

      assert ItemFolders.blockers(ctx.folder, ignore: [ctx.own]) == []
    end

    test "a .mydia-trash directory is skipped", ctx do
      trash = Path.join(ctx.dir, ".mydia-trash/abc")
      File.mkdir_p!(trash)
      File.write!(Path.join(trash, "Quiet Orchard.mkv"), "video")

      assert ItemFolders.blockers(ctx.folder, ignore: [ctx.own]) == []
    end

    test "an unreadable subdirectory blocks", ctx do
      locked = Path.join(ctx.dir, "Locked")
      File.mkdir_p!(locked)
      File.chmod!(locked, 0o000)
      on_exit(fn -> File.chmod(locked, 0o755) end)

      assert ItemFolders.blockers(ctx.folder, ignore: [ctx.own]) ==
               [{:unreadable, "Harbor Lights (2011)/Locked"}]
    end

    test "a folder does not claim rows in a sibling that shares its name as a prefix", ctx do
      other = media_item_fixture(%{type: "movie", title: "Quiet Orchard"})

      {:ok, _} =
        Library.create_scanned_media_file(%{
          relative_path: "Harbor Lights (2011) Extended/Quiet Orchard.mkv",
          library_path_id: ctx.lp.id,
          media_item_id: other.id,
          size: 5
        })

      assert ItemFolders.blockers(ctx.folder, ignore: [ctx.own]) == []
    end

    test "LIKE wildcards in a folder name match literally", %{root: root, lp: lp} do
      item = media_item_fixture(%{type: "movie", title: "Paper Harbor"})
      other = media_item_fixture(%{type: "movie", title: "Quiet Orchard"})

      for rel <- ["100% Pure_Reel/Paper Harbor.mkv", "100X PureXReel/Quiet Orchard.mkv"] do
        File.mkdir_p!(Path.dirname(Path.join(root, rel)))
        File.write!(Path.join(root, rel), "video")
      end

      {:ok, own} =
        Library.create_scanned_media_file(%{
          relative_path: "100% Pure_Reel/Paper Harbor.mkv",
          library_path_id: lp.id,
          media_item_id: item.id,
          size: 5
        })

      {:ok, _} =
        Library.create_scanned_media_file(%{
          relative_path: "100X PureXReel/Quiet Orchard.mkv",
          library_path_id: lp.id,
          media_item_id: other.id,
          size: 5
        })

      own = Repo.preload(own, :library_path)
      [folder] = ItemFolders.folders_for([own])

      assert ItemFolders.blockers(folder, ignore: [own]) == []
    end

    test "returns at most five blockers", ctx do
      for n <- 1..7, do: File.write!(Path.join(ctx.dir, "Stray #{n}.mkv"), "video")

      assert length(ItemFolders.blockers(ctx.folder, ignore: [ctx.own])) == 5
    end
  end
end
