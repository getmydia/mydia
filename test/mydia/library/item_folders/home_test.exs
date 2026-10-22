defmodule Mydia.Library.ItemFolders.HomeTest do
  use Mydia.DataCase, async: true

  import Mydia.SettingsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Library.ItemFolders.Home

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    root = Path.join(tmp, "lib")
    File.mkdir_p!(root)
    %{root: root, lp: library_path_fixture(%{path: root, type: "mixed"})}
  end

  defp movie(attrs \\ %{}) do
    media_item_fixture(
      Map.merge(%{type: "movie", title: "Quiet Harbor", year: 2011, tmdb_id: 90001}, attrs)
    )
  end

  defp movie_file(item, lp, rel, attrs \\ %{}) do
    media_file_fixture(
      Map.merge(%{media_item_id: item.id, library_path_id: lp.id, relative_path: rel}, attrs)
    )
  end

  defp show do
    media_item_fixture(%{type: "tv_show", title: "Lantern Bay", year: 2020, tvdb_id: 70001})
  end

  defp episode_file(show, lp, rel, season) do
    ep = episode_fixture(%{media_item_id: show.id, season_number: season})
    media_file_fixture(%{episode_id: ep.id, library_path_id: lp.id, relative_path: rel})
  end

  describe "find/3" do
    test "a folder tagged with the item's tmdb id", %{lp: lp, root: root} do
      item = movie()
      movie_file(item, lp, "Quiet Harbor (2011) {tmdb-90001}/Quiet Harbor.mkv")

      assert {:ok, folder} = Home.find(item, lp)
      assert folder.relative == "Quiet Harbor (2011) {tmdb-90001}"
      assert folder.absolute == Path.join(root, "Quiet Harbor (2011) {tmdb-90001}")
    end

    test "an untagged folder whose title matches", %{lp: lp} do
      item = movie()
      movie_file(item, lp, "Quiet Harbor (2011)/Quiet Harbor.mkv")

      assert {:ok, %{relative: "Quiet Harbor (2011)"}} = Home.find(item, lp)
    end

    test "a misidentified file in another title's folder is not trusted", %{lp: lp} do
      item = movie()
      movie_file(item, lp, "Copper Meadow (2019)/Copper Meadow.mkv")

      assert Home.find(item, lp) == :none
    end

    test "a sequel's folder is not trusted", %{lp: lp} do
      item = movie()
      movie_file(item, lp, "Quiet Harbor 2 (2011)/Quiet Harbor 2.mkv")

      assert Home.find(item, lp) == :none
    end

    test "a folder tagged with a different id is rejected even with the right title", %{lp: lp} do
      item = movie()
      movie_file(item, lp, "Quiet Harbor (2011) {tmdb-55555}/Quiet Harbor.mkv")

      assert Home.find(item, lp) == :none
    end

    test "a folder carrying the item's id and another id of the same provider is rejected", %{
      lp: lp
    } do
      item = movie()
      movie_file(item, lp, "Quiet Harbor (2011) {tmdb-90001} {tmdb-55555}/a.mkv")

      assert Home.find(item, lp) == :none
    end

    test "a folder whose year contradicts the item's is rejected", %{lp: lp} do
      item = movie()
      movie_file(item, lp, "Quiet Harbor (1987)/Quiet Harbor.mkv")

      assert Home.find(item, lp) == :none
    end

    test "a file loose in the library root gives no folder", %{lp: lp} do
      item = movie()
      movie_file(item, lp, "Quiet Harbor (2011).mkv")

      assert Home.find(item, lp) == :none
    end

    test "trashed files and extras are ignored", %{lp: lp} do
      item = movie()

      movie_file(item, lp, "Quiet Harbor (2011)/a.mkv", %{
        trashed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

      movie_file(item, lp, "Quiet Harbor (2011) {tmdb-90001}/trailer.mkv", %{extra_kind: :trailer})

      assert Home.find(item, lp) == :none
    end

    test "files in another library are ignored", %{lp: lp, tmp_dir: tmp} do
      other_root = Path.join(tmp, "other")
      File.mkdir_p!(other_root)
      other = library_path_fixture(%{path: other_root, type: "mixed"})
      item = movie()
      movie_file(item, other, "Quiet Harbor (2011)/Quiet Harbor.mkv")

      assert Home.find(item, lp) == :none
    end

    test "the folder holding the most files wins; ties go to the first by name", %{lp: lp} do
      item = movie()
      movie_file(item, lp, "Quiet Harbor (2011)/a.mkv")
      movie_file(item, lp, "Quiet Harbor {tmdb-90001}/a.mkv")
      movie_file(item, lp, "Quiet Harbor {tmdb-90001}/b.mkv")

      assert {:ok, %{relative: "Quiet Harbor {tmdb-90001}"}} = Home.find(item, lp)

      tie = movie(%{tmdb_id: 90002, title: "Rust Valley", year: 2013})
      movie_file(tie, lp, "Rust Valley (2013) B/a.mkv")
      movie_file(tie, lp, "Rust Valley (2013)/a.mkv")

      assert {:ok, %{relative: "Rust Valley (2013)"}} = Home.find(tie, lp)
    end

    test ":prefer_file_id wins over a larger folder", %{lp: lp} do
      item = movie()
      target = movie_file(item, lp, "Quiet Harbor (2011)/old.mkv")
      movie_file(item, lp, "Quiet Harbor {tmdb-90001}/a.mkv")
      movie_file(item, lp, "Quiet Harbor {tmdb-90001}/b.mkv")

      assert {:ok, %{relative: "Quiet Harbor (2011)"}} =
               Home.find(item, lp, prefer_file_id: target.id)
    end

    test ":prefer_file_id in an untrusted folder falls back to the fullest trusted folder", %{
      lp: lp
    } do
      item = movie()
      target = movie_file(item, lp, "Copper Meadow (2019)/x.mkv")
      movie_file(item, lp, "Quiet Harbor (2011)/a.mkv")
      movie_file(item, lp, "Quiet Harbor {tmdb-90001}/a.mkv")
      movie_file(item, lp, "Quiet Harbor {tmdb-90001}/b.mkv")

      assert {:ok, %{relative: "Quiet Harbor {tmdb-90001}"}} =
               Home.find(item, lp, prefer_file_id: target.id)
    end

    test "an imdb tag matches case-insensitively", %{lp: lp} do
      item = movie(%{imdb_id: "tt0000123"})
      movie_file(item, lp, "Quiet Harbor {IMDB-TT0000123}/Quiet Harbor.mkv")

      assert {:ok, %{relative: "Quiet Harbor {IMDB-TT0000123}"}} = Home.find(item, lp)
    end

    test "a TV show is found through its episodes' files", %{lp: lp} do
      item = show()
      episode_file(item, lp, "Lantern Bay (2020) [tvdb-70001]/Season 1/Lantern Bay S01E01.mkv", 1)

      assert {:ok, %{relative: "Lantern Bay (2020) [tvdb-70001]"}} = Home.find(item, lp)
    end
  end

  describe "season_folder_name/4" do
    test "reuses the season folder already holding that season", %{lp: lp, root: root} do
      item = show()
      episode_file(item, lp, "Lantern Bay (2020) [tvdb-70001]/Season 1/Lantern Bay S01E01.mkv", 1)
      base = Path.join(root, "Lantern Bay (2020) [tvdb-70001]")

      assert Home.season_folder_name(item, lp, base, 1) == "Season 1"
      assert Home.season_folder_name(item, lp, base, 2) == nil
    end
  end
end
