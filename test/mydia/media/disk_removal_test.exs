defmodule Mydia.Media.DiskRemovalTest do
  use Mydia.DataCase, async: true

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Library
  alias Mydia.Library.MediaFile
  alias Mydia.Library.MediaFileEpisode
  alias Mydia.Media.DiskRemoval
  alias Mydia.Media.DiskRemoval.Preview
  alias Mydia.Repo
  alias Mydia.Settings.LibraryPath
  alias Mydia.Subtitles.Subtitle

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    root = Path.join(tmp, "lib")
    File.mkdir_p!(root)
    %{root: root, lp: library_path_fixture(%{path: root, type: "mixed"})}
  end

  defp movie_file(lp, item, rel) do
    absolute = Path.join(lp.path, rel)
    File.mkdir_p!(Path.dirname(absolute))
    File.write!(absolute, "video")

    {:ok, file} =
      Library.create_scanned_media_file(%{
        relative_path: rel,
        library_path_id: lp.id,
        media_item_id: item.id,
        size: 5
      })

    file
  end

  defp subtitle!(file, path, hash) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "1\n")

    %Subtitle{}
    |> Subtitle.changeset(%{
      media_file_id: file.id,
      language: "en",
      provider: "test",
      subtitle_hash: hash,
      file_path: path,
      format: "srt"
    })
    |> Repo.insert!()
  end

  defp file_ids(plan), do: plan.files |> Enum.map(& &1.id) |> Enum.sort()

  describe "plan/1" do
    test "collects movie files and every file whose primary episode is the show's", %{lp: lp} do
      movie = media_item_fixture(%{type: "movie", title: "Harbor Lights"})
      movie_row = movie_file(lp, movie, "Harbor Lights (2011)/Harbor Lights (2011).mkv")

      show = media_item_fixture(%{type: "tv_show", title: "Tin Kettle", tvdb_id: 9001})
      e1 = episode_fixture(media_item_id: show.id, season_number: 1, episode_number: 1)
      e2 = episode_fixture(media_item_id: show.id, season_number: 1, episode_number: 2)

      linked =
        media_file_fixture(
          episode_id: e1.id,
          library_path_id: lp.id,
          relative_path: "Tin Kettle/Season 01/Tin Kettle S01E01.mkv"
        )

      # Written before media_file_episodes existed: episode_id set, no link row.
      unlinked =
        Repo.insert!(%MediaFile{
          episode_id: e2.id,
          library_path_id: lp.id,
          relative_path: "Tin Kettle/Season 01/Tin Kettle S01E02.mkv"
        })

      # Primary episode in another show, linked to e2 only through the join:
      # that show's file, so deleting Tin Kettle must leave it alone.
      other = media_item_fixture(%{type: "tv_show", title: "Paper Harbor", tvdb_id: 9002})
      other_ep = episode_fixture(media_item_id: other.id, season_number: 1, episode_number: 1)

      theirs =
        media_file_fixture(
          episode_id: other_ep.id,
          library_path_id: lp.id,
          relative_path: "Paper Harbor/Paper Harbor S01E01.mkv"
        )

      Repo.insert!(%MediaFileEpisode{media_file_id: theirs.id, episode_id: e2.id})

      assert file_ids(DiskRemoval.plan([movie.id])) == [movie_row.id]

      show_plan = DiskRemoval.plan([show.id])
      assert file_ids(show_plan) == Enum.sort([linked.id, unlinked.id])
      assert Enum.all?(show_plan.files, &match?(%LibraryPath{}, &1.library_path))
    end

    test "keeps only the subtitles that sit beside their video", %{root: root, lp: lp} do
      item = media_item_fixture(%{type: "movie", title: "Harbor Lights"})
      file = movie_file(lp, item, "Harbor Lights (2011)/Harbor Lights (2011).mkv")
      beside = Path.join(root, "Harbor Lights (2011)/Harbor Lights (2011).en.srt")
      subtitle!(file, beside, "hash-beside")
      subtitle!(file, Path.join(root, "cache/extracted.en.srt"), "hash-cache")

      assert DiskRemoval.plan([item.id]).subtitle_paths == %{file.id => [beside]}
    end
  end

  describe "run/1" do
    test "deletes files and subtitles, removes the clean folder and prunes its parent",
         %{root: root, lp: lp} do
      item = media_item_fixture(%{type: "movie", title: "Harbor Lights"})
      rel = "Collection A/Harbor Lights (2011)/Harbor Lights (2011).mkv"
      file = movie_file(lp, item, rel)
      subtitle!(file, Path.join(root, "Collection A/Harbor Lights (2011)/hl.en.srt"), "hash-1")
      cached = Path.join(root, "cache/extracted.en.srt")
      subtitle!(file, cached, "hash-2")
      File.write!(Path.join(root, "Collection A/Harbor Lights (2011)/poster.jpg"), "art")

      plan = DiskRemoval.plan([item.id])
      Repo.delete!(item)

      folder = Path.join(root, "Collection A/Harbor Lights (2011)")

      assert DiskRemoval.run(plan) ==
               %DiskRemoval{files_failed: 0, folders_removed: [folder], folders_kept: []}

      refute File.exists?(Path.join(root, "Collection A"))
      assert File.exists?(cached)
    end

    test "in a kept folder removes only the item's files, then prunes what they emptied",
         %{root: root, lp: lp} do
      item = media_item_fixture(%{type: "movie", title: "Reel One"})
      file = movie_file(lp, item, "Shared Reels/Disc 1/Reel One.mkv")
      srt = Path.join(root, "Shared Reels/Disc 1/Reel One.en.srt")
      subtitle!(file, srt, "hash-one")
      File.write!(Path.join(root, "Shared Reels/Disc 1/Reel One.nfo"), "<movie/>")

      other = media_item_fixture(%{type: "movie", title: "Reel Two"})
      movie_file(lp, other, "Shared Reels/Reel Two.mkv")
      File.write!(Path.join(root, "Shared Reels/poster.jpg"), "art")

      plan = DiskRemoval.plan([item.id])
      Repo.delete!(item)

      folder = Path.join(root, "Shared Reels")

      assert %DiskRemoval{
               files_failed: 0,
               folders_removed: [],
               folders_kept: [{^folder, {:blocked, [{:media_file, "Shared Reels/Reel Two.mkv"}]}}]
             } = DiskRemoval.run(plan)

      refute File.exists?(Path.join(root, "Shared Reels/Disc 1"))
      assert File.exists?(Path.join(root, "Shared Reels/Reel Two.mkv"))
      assert File.exists?(Path.join(root, "Shared Reels/poster.jpg"))
    end

    test "an empty plan does nothing" do
      assert DiskRemoval.run(%DiskRemoval.Plan{}) == %DiskRemoval{}
    end
  end

  describe "preview/1" do
    test "names folders that would go and stay, counts loose files, touches nothing",
         %{root: root, lp: lp} do
      item = media_item_fixture(%{type: "movie", title: "Harbor Lights"})
      movie_file(lp, item, "Harbor Lights (2011)/Harbor Lights (2011).mkv")
      movie_file(lp, item, "Shared Reels/Harbor Lights alt.mkv")
      movie_file(lp, item, "Harbor Lights loose.mkv")

      other = media_item_fixture(%{type: "movie", title: "Reel Two"})
      movie_file(lp, other, "Shared Reels/Reel Two.mkv")

      assert DiskRemoval.preview(item) == %Preview{
               remove: [Path.join(root, "Harbor Lights (2011)")],
               keep: [
                 {Path.join(root, "Shared Reels"), [{:media_file, "Shared Reels/Reel Two.mkv"}]}
               ],
               loose_files: 1
             }

      assert File.exists?(Path.join(root, "Harbor Lights (2011)/Harbor Lights (2011).mkv"))
      assert File.exists?(Path.join(root, "Harbor Lights loose.mkv"))
    end
  end
end
