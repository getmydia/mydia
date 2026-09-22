defmodule Mydia.Library.ItemFoldersTest do
  use Mydia.DataCase, async: true

  import Mydia.SettingsFixtures

  alias Mydia.Library.ItemFolders
  alias Mydia.Library.ItemFolders.Folder
  alias Mydia.Library.MediaFile

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
end
