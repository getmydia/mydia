defmodule Mydia.Library.MultiEpisodeRelinkTest do
  use Mydia.DataCase, async: true

  import Mydia.Factory

  alias Mydia.Library.MediaFile
  alias Mydia.Library.MultiEpisodeRelink
  alias Mydia.Repo

  defp legacy_file(show, library_path, relative_path, primary_episode) do
    # A row as the old matcher left it: episode_id set to the first episode,
    # and a single join row, with the rest of the file's episodes dropped.
    {:ok, file} =
      %MediaFile{}
      |> MediaFile.changeset(%{
        episode_id: primary_episode.id,
        library_path_id: library_path.id,
        relative_path: relative_path,
        path: "/series/#{relative_path}",
        size: 1_000_000
      })
      |> Repo.insert()

    {:ok, _} = Mydia.Library.ensure_episode_link(file)

    _ = show
    file
  end

  describe "run/0" do
    setup do
      show = insert(:tv_show, %{title: "Fathom Rift", year: 2015})
      library_path = insert(:library_path, %{type: :series})

      ep9 = insert(:episode, %{media_item: show, season_number: 1, episode_number: 9})
      ep10 = insert(:episode, %{media_item: show, season_number: 1, episode_number: 10})

      {:ok, show: show, library_path: library_path, ep9: ep9, ep10: ep10}
    end

    test "adds the dropped episode of a legacy multi-episode file", %{
      show: show,
      library_path: library_path,
      ep9: ep9,
      ep10: ep10
    } do
      file =
        legacy_file(
          show,
          library_path,
          "Fathom Rift S01E09E10 Tidewater (1080p x265 10bit).mkv",
          ep9
        )

      # Precondition: the trailing episode looks un-downloaded.
      assert [] = Repo.preload(ep10, :media_files).media_files

      assert {:ok, %{files_relinked: 1, links_added: 1}} = MultiEpisodeRelink.run()

      assert [%MediaFile{id: id10}] = Repo.preload(ep10, :media_files).media_files
      assert id10 == file.id

      # The primary episode keeps the file, and is not duplicated.
      assert [%MediaFile{id: id9}] = Repo.preload(ep9, :media_files).media_files
      assert id9 == file.id
    end

    test "is idempotent", %{show: show, library_path: library_path, ep9: ep9, ep10: ep10} do
      legacy_file(show, library_path, "Fathom Rift S01E09E10 Tidewater.mkv", ep9)

      assert {:ok, %{files_relinked: 1}} = MultiEpisodeRelink.run()
      assert {:ok, %{files_relinked: 0, links_added: 0}} = MultiEpisodeRelink.run()

      assert [_only_one] = Repo.preload(ep10, :media_files).media_files
    end

    test "leaves single-episode files alone", %{
      show: show,
      library_path: library_path,
      ep9: ep9,
      ep10: ep10
    } do
      legacy_file(show, library_path, "Fathom Rift S01E09 Tidewater.mkv", ep9)

      assert {:ok, %{files_relinked: 0, links_added: 0}} = MultiEpisodeRelink.run()

      assert [_] = Repo.preload(ep9, :media_files).media_files
      assert [] = Repo.preload(ep10, :media_files).media_files
    end

    test "relinks every file when the work spans several batches", %{
      show: show,
      library_path: library_path
    } do
      # Four two-episode files read with batch_size 2, so the keyset loop has to
      # page three times. With a bug in the cursor this either loops forever or
      # relinks only the first page.
      pairs =
        for {first, second} <- [{1, 2}, {3, 4}, {5, 6}, {7, 8}] do
          ep_a = insert(:episode, %{media_item: show, season_number: 2, episode_number: first})
          ep_b = insert(:episode, %{media_item: show, season_number: 2, episode_number: second})

          legacy_file(
            show,
            library_path,
            "Fathom Rift S02E0#{first}E0#{second} Tidewater.mkv",
            ep_a
          )

          {ep_a, ep_b}
        end

      assert {:ok, %{files_relinked: 4, links_added: 4}} =
               MultiEpisodeRelink.run(batch_size: 2)

      for {ep_a, ep_b} <- pairs do
        assert [_] = Repo.preload(ep_a, :media_files).media_files
        assert [_] = Repo.preload(ep_b, :media_files).media_files
      end
    end

    test "does not invent a link for an episode the show does not have", %{
      show: show,
      library_path: library_path,
      ep9: ep9
    } do
      # E11 does not exist on this show; only the real episodes get linked.
      legacy_file(show, library_path, "Fathom Rift S01E09E11 Tidewater.mkv", ep9)

      assert {:ok, %{links_added: added}} = MultiEpisodeRelink.run()
      assert added == 0

      assert [_] = Repo.preload(ep9, :media_files).media_files
    end
  end
end
