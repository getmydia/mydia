defmodule Mydia.Library.PruneTest do
  use Mydia.DataCase, async: true

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Library.Prune

  defp episode_with(file_names, duration) do
    show = media_item_fixture(%{type: "tv_show", title: "Rick and Morty", year: 2013})
    episode = episode_fixture(%{media_item_id: show.id, season_number: 2, episode_number: 3})
    lp = library_path_fixture(%{type: "series"})

    files =
      Enum.map(file_names, fn {name, attrs} ->
        attrs
        |> Map.merge(%{
          episode_id: episode.id,
          library_path_id: lp.id,
          relative_path: name,
          metadata: %{"container" => "mp4", "duration" => duration}
        })
        |> media_file_fixture()
      end)

    {episode, files}
  end

  describe "plan/0" do
    test "separates prunable decisions from refusals" do
      {_episode, _files} =
        episode_with(
          [
            {"Rick and Morty/Season 02/Rick.and.Morty.S02E03.1080p.BluRay.x265.mp4",
             %{resolution: "1080p", codec: "hevc", bitrate: 2_002_656}},
            {"Rick and Morty/Season 02/Rick.and.Morty.S02E03.360p.WEBRip.x264.mp4",
             %{resolution: "360p", codec: "h264", bitrate: 1_000_000}}
          ],
          1320.0
        )

      movie = media_item_fixture(%{type: "movie", title: "Monsters University", year: 2013})
      lp = library_path_fixture(%{type: "movies"})

      for {name, duration} <- [
            {"MU/Monsters University (2013).mkv", 6360.0},
            {"MU/Campus Life.mkv", 280.0}
          ] do
        media_file_fixture(%{
          media_item_id: movie.id,
          library_path_id: lp.id,
          relative_path: name,
          metadata: %{"container" => "mkv", "duration" => duration}
        })
      end

      plan = Prune.plan()

      assert [decision] = plan.decisions
      assert decision.keeper.relative_path =~ "1080p"

      assert [{group, :duration_mismatch, _detail}] = plan.refusals
      assert group.subject_id == movie.id
    end
  end

  describe "execute/2" do
    test "trashes the selected losers and leaves the keeper active" do
      {_episode, files} =
        episode_with(
          [
            {"Rick and Morty/Season 02/Rick.and.Morty.S02E03.1080p.BluRay.x265.mp4",
             %{resolution: "1080p", codec: "hevc", bitrate: 2_002_656}},
            {"Rick and Morty/Season 02/Rick.and.Morty.S02E03.360p.WEBRip.x264.mp4",
             %{resolution: "360p", codec: "h264", bitrate: 1_000_000}}
          ],
          1320.0
        )

      loser = Enum.find(files, &(&1.relative_path =~ "360p"))
      keeper = Enum.find(files, &(&1.relative_path =~ "1080p"))

      result = Prune.execute([loser.id], "admin")

      assert Enum.map(result.trashed, & &1.id) == [loser.id]
      assert result.failed == []
      assert result.aborted == []

      assert Mydia.Repo.get!(Mydia.Library.MediaFile, loser.id).trashed_at
      refute Mydia.Repo.get!(Mydia.Library.MediaFile, keeper.id).trashed_at
    end

    test "refuses to trash a file from a refused group even when handed its id" do
      movie = media_item_fixture(%{type: "movie", title: "Monsters University", year: 2013})
      lp = library_path_fixture(%{type: "movies"})

      files =
        for {name, duration} <- [
              {"MU/Monsters University (2013).mkv", 6360.0},
              {"MU/Campus Life.mkv", 280.0}
            ] do
          media_file_fixture(%{
            media_item_id: movie.id,
            library_path_id: lp.id,
            relative_path: name,
            metadata: %{"container" => "mkv", "duration" => duration}
          })
        end

      extra = Enum.find(files, &(&1.relative_path =~ "Campus Life"))

      result = Prune.execute([extra.id], "admin")

      assert result.trashed == []
      assert [{id, :duration_mismatch}] = result.aborted
      assert id == extra.id
      refute Mydia.Repo.get!(Mydia.Library.MediaFile, extra.id).trashed_at
    end

    test "refuses to trash a proposed keeper" do
      {_episode, files} =
        episode_with(
          [
            {"Rick and Morty/Season 02/Rick.and.Morty.S02E03.1080p.BluRay.x265.mp4",
             %{resolution: "1080p", codec: "hevc", bitrate: 2_002_656}},
            {"Rick and Morty/Season 02/Rick.and.Morty.S02E03.360p.WEBRip.x264.mp4",
             %{resolution: "360p", codec: "h264", bitrate: 1_000_000}}
          ],
          1320.0
        )

      # Selecting every file in a group would leave the item with nothing.
      ids = Enum.map(files, & &1.id)
      result = Prune.execute(ids, "admin")

      assert length(result.trashed) == 1
      assert [{_id, :would_leave_no_file}] = result.aborted
    end
  end
end
