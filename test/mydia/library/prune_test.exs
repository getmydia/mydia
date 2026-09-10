defmodule Mydia.Library.PruneTest do
  use Mydia.DataCase, async: true
  use Oban.Testing, repo: Mydia.Repo

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Library.MediaFile
  alias Mydia.Library.Prune

  defp trashed_at(id), do: Mydia.Repo.get!(MediaFile, id).trashed_at

  defp episode_with(file_names, duration) do
    show = media_item_fixture(%{type: "tv_show", title: "Harbor Lights", year: 2013})
    episode_with(show, 3, file_names, duration)
  end

  # Attaches a new episode to an existing show, so a test can put two
  # episodes of the same show through undo/2 in one call.
  defp episode_with(show, episode_number, file_names, duration) do
    episode =
      episode_fixture(%{
        media_item_id: show.id,
        season_number: 2,
        episode_number: episode_number
      })

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

  # A movie holding its own file plus one from another title's folder, with
  # lengths far enough apart that Eligibility refuses the group.
  defp misfiled_movie do
    movie = media_item_fixture(%{type: "movie", title: "Zephyr Station", year: 2030})
    lp = library_path_fixture(%{type: "movies"})

    [own, stray] =
      for {path, seconds} <- [
            {"Zephyr Station (2030)/Zephyr.Station.2030.1080p.mkv", 6000.0},
            {"Starveil (2031)/Starveil.2031.1080p.mkv", 7000.0}
          ] do
        media_file_fixture(%{
          media_item_id: movie.id,
          library_path_id: lp.id,
          relative_path: path,
          metadata: %{"container" => "mkv", "duration" => seconds}
        })
      end

    {movie, own, stray}
  end

  @same_episode_twice [
    {"Harbor Lights/Season 02/Harbor.Lights.S02E03.1080p.BluRay.x265.mp4",
     %{resolution: "1080p", codec: "hevc", bitrate: 2_002_656}},
    {"Harbor Lights/Season 02/Harbor.Lights.S02E03.360p.WEBRip.x264.mp4",
     %{resolution: "360p", codec: "h264", bitrate: 1_000_000}}
  ]

  describe "plan/0" do
    test "separates prunable decisions from refusals" do
      {_episode, _files} =
        episode_with(
          [
            {"Harbor Lights/Season 02/Harbor.Lights.S02E03.1080p.BluRay.x265.mp4",
             %{resolution: "1080p", codec: "hevc", bitrate: 2_002_656}},
            {"Harbor Lights/Season 02/Harbor.Lights.S02E03.360p.WEBRip.x264.mp4",
             %{resolution: "360p", codec: "h264", bitrate: 1_000_000}}
          ],
          1320.0
        )

      movie = media_item_fixture(%{type: "movie", title: "Tidepool Academy", year: 2013})
      lp = library_path_fixture(%{type: "movies"})

      for {name, duration} <- [
            {"TA/Tidepool Academy (2013).mkv", 6360.0},
            {"TA/Orientation Week.mkv", 280.0}
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
            {"Harbor Lights/Season 02/Harbor.Lights.S02E03.1080p.BluRay.x265.mp4",
             %{resolution: "1080p", codec: "hevc", bitrate: 2_002_656}},
            {"Harbor Lights/Season 02/Harbor.Lights.S02E03.360p.WEBRip.x264.mp4",
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
      movie = media_item_fixture(%{type: "movie", title: "Tidepool Academy", year: 2013})
      lp = library_path_fixture(%{type: "movies"})

      files =
        for {name, duration} <- [
              {"TA/Tidepool Academy (2013).mkv", 6360.0},
              {"TA/Orientation Week.mkv", 280.0}
            ] do
          media_file_fixture(%{
            media_item_id: movie.id,
            library_path_id: lp.id,
            relative_path: name,
            metadata: %{"container" => "mkv", "duration" => duration}
          })
        end

      extra = Enum.find(files, &(&1.relative_path =~ "Orientation Week"))

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
            {"Harbor Lights/Season 02/Harbor.Lights.S02E03.1080p.BluRay.x265.mp4",
             %{resolution: "1080p", codec: "hevc", bitrate: 2_002_656}},
            {"Harbor Lights/Season 02/Harbor.Lights.S02E03.360p.WEBRip.x264.mp4",
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

  describe "execute/3 with a keeper override" do
    test "trashes the file the operator selected, honoring the override, not the ranked keeper" do
      {episode, files} =
        episode_with(
          [
            {"Harbor Lights/Season 02/Harbor.Lights.S02E03.1080p.BluRay.x265.mp4",
             %{resolution: "1080p", codec: "hevc", bitrate: 2_002_656}},
            {"Harbor Lights/Season 02/Harbor.Lights.S02E03.360p.WEBRip.x264.mp4",
             %{resolution: "360p", codec: "h264", bitrate: 1_000_000}}
          ],
          1320.0
        )

      ranked_keeper = Enum.find(files, &(&1.relative_path =~ "1080p"))
      overridden_keeper = Enum.find(files, &(&1.relative_path =~ "360p"))

      # The operator overrode the keeper to the lower-quality file, then chose
      # to trash the ranked (higher-quality) one.
      keepers = %{episode.id => overridden_keeper.id}
      result = Prune.execute([ranked_keeper.id], "admin", keepers)

      assert Enum.map(result.trashed, & &1.id) == [ranked_keeper.id]
      assert result.failed == []
      assert result.aborted == []

      assert Mydia.Repo.get!(Mydia.Library.MediaFile, ranked_keeper.id).trashed_at
      refute Mydia.Repo.get!(Mydia.Library.MediaFile, overridden_keeper.id).trashed_at
    end

    test "still refuses to leave a group with zero files under an override" do
      {episode, files} =
        episode_with(
          [
            {"Harbor Lights/Season 02/Harbor.Lights.S02E03.1080p.BluRay.x265.mp4",
             %{resolution: "1080p", codec: "hevc", bitrate: 2_002_656}},
            {"Harbor Lights/Season 02/Harbor.Lights.S02E03.360p.WEBRip.x264.mp4",
             %{resolution: "360p", codec: "h264", bitrate: 1_000_000}}
          ],
          1320.0
        )

      ranked_keeper = Enum.find(files, &(&1.relative_path =~ "1080p"))
      overridden_keeper = Enum.find(files, &(&1.relative_path =~ "360p"))
      keepers = %{episode.id => overridden_keeper.id}

      ids = Enum.map(files, & &1.id)
      result = Prune.execute(ids, "admin", keepers)

      assert Enum.map(result.trashed, & &1.id) == [ranked_keeper.id]
      assert result.aborted == [{overridden_keeper.id, :would_leave_no_file}]

      assert Mydia.Repo.get!(Mydia.Library.MediaFile, ranked_keeper.id).trashed_at
      refute Mydia.Repo.get!(Mydia.Library.MediaFile, overridden_keeper.id).trashed_at
    end
  end

  describe "undo/2" do
    setup do
      {episode, files} =
        episode_with(
          [
            {"Harbor Lights/Season 02/Harbor.Lights.S02E03.1080p.BluRay.x265.mp4",
             %{resolution: "1080p", codec: "hevc", bitrate: 2_002_656, size: 3_000_000_000}},
            {"Harbor Lights/Season 02/Harbor.Lights.S02E03.360p.WEBRip.x264.mp4",
             %{resolution: "360p", codec: "h264", bitrate: 1_000_000, size: 1_000_000_000}}
          ],
          1320.0
        )

      keeper = Enum.find(files, &(&1.relative_path =~ "1080p"))
      loser = Enum.find(files, &(&1.relative_path =~ "360p"))

      %{episode: episode, keeper: keeper, loser: loser}
    end

    test "restores a trashed file and clears trashed_at", %{loser: loser} do
      %{trashed: [trashed]} = Prune.execute([loser.id], "admin")
      assert trashed_at(trashed.id)

      result = Prune.undo([trashed.id], "admin")

      assert [restored] = result.restored
      assert restored.id == loser.id
      assert result.failed == []
      refute trashed_at(loser.id)
    end

    test "skips an id that is not trashed, without reporting it as a failure",
         %{keeper: keeper} do
      # The toast can outlive the state it describes: TrashCleanup can purge a
      # row, a scan can restore it, or another admin session can act on it.
      # Restoring something that is not in the trash is not a no-op below this
      # layer, so it must be filtered out before the call.
      refute trashed_at(keeper.id)

      result = Prune.undo([keeper.id], "admin")

      assert result.restored == []
      assert result.failed == []
    end

    test "restores the trashed ids and ignores the untrashed ones in one call",
         %{keeper: keeper, loser: loser} do
      %{trashed: [_]} = Prune.execute([loser.id], "admin")

      result = Prune.undo([loser.id, keeper.id], "admin")

      assert [restored] = result.restored
      assert restored.id == loser.id
      refute trashed_at(loser.id)
    end

    test "ignores an id that matches no media file" do
      result = Prune.undo([Ecto.UUID.generate()], "admin")

      assert result.restored == []
      assert result.failed == []
    end

    test "emits one prune_undone event for the group, not one per file",
         %{loser: loser, episode: episode} do
      %{trashed: [_]} = Prune.execute([loser.id], "admin")

      Prune.undo([loser.id], "admin")

      events =
        Mydia.Events.Event
        |> Ecto.Query.where(type: "media_file.prune_undone")
        |> Mydia.Repo.all()

      assert [event] = events
      assert event.resource_type == "episode"
      assert event.resource_id == episode.id
      assert event.metadata["restored"] == [loser.relative_path]
      assert event.metadata["bytes_restored"] == 1_000_000_000
    end

    test "emits one prune_undone event per episode, not per show, when undoing across episodes of the same show" do
      show = media_item_fixture(%{type: "tv_show", title: "Harbor Lights", year: 2013})

      {episode_a, files_a} =
        episode_with(
          show,
          3,
          [
            {"Harbor Lights/Season 02/Harbor.Lights.S02E03.1080p.BluRay.x265.mp4",
             %{resolution: "1080p", codec: "hevc", bitrate: 2_002_656, size: 3_000_000_000}},
            {"Harbor Lights/Season 02/Harbor.Lights.S02E03.360p.WEBRip.x264.mp4",
             %{resolution: "360p", codec: "h264", bitrate: 1_000_000, size: 1_000_000_000}}
          ],
          1320.0
        )

      {episode_b, files_b} =
        episode_with(
          show,
          4,
          [
            {"Harbor Lights/Season 02/Harbor.Lights.S02E04.1080p.BluRay.x265.mp4",
             %{resolution: "1080p", codec: "hevc", bitrate: 2_002_656, size: 3_000_000_000}},
            {"Harbor Lights/Season 02/Harbor.Lights.S02E04.360p.WEBRip.x264.mp4",
             %{resolution: "360p", codec: "h264", bitrate: 1_000_000, size: 1_000_000_000}}
          ],
          1320.0
        )

      loser_a = Enum.find(files_a, &(&1.relative_path =~ "360p"))
      loser_b = Enum.find(files_b, &(&1.relative_path =~ "360p"))

      %{trashed: [_]} = Prune.execute([loser_a.id], "admin")
      %{trashed: [_]} = Prune.execute([loser_b.id], "admin")

      result = Prune.undo([loser_a.id, loser_b.id], "admin")

      assert length(result.restored) == 2
      assert result.failed == []

      events =
        Mydia.Events.Event
        |> Ecto.Query.where(type: "media_file.prune_undone")
        |> Mydia.Repo.all()

      assert length(events) == 2

      by_resource_id = Map.new(events, &{&1.resource_id, &1})

      assert event_a = Map.get(by_resource_id, episode_a.id)
      assert event_b = Map.get(by_resource_id, episode_b.id)

      assert event_a.resource_type == "episode"
      assert event_b.resource_type == "episode"

      assert event_a.metadata["restored"] == [loser_a.relative_path]
      assert event_b.metadata["restored"] == [loser_b.relative_path]
    end
  end

  describe "plan/1 suspects" do
    test "names the stray file of a refused group" do
      {movie, _own, stray} = misfiled_movie()

      assert %{suspects: suspects} = Prune.plan()
      assert suspects[movie.id] == MapSet.new([stray.id])
    end

    test "leaves eligible groups out" do
      {episode, _files} = episode_with(@same_episode_twice, 1320.0)

      assert %{suspects: suspects} = Prune.plan()
      refute Map.has_key?(suspects, episode.id)
    end
  end

  describe "send_to_review/2" do
    test "sends the requested file to Review and leaves the rest attached" do
      {_movie, own, stray} = misfiled_movie()

      assert %{returned: [%MediaFile{id: id}], failed: [], aborted: []} =
               Prune.send_to_review([stray.id], "42")

      assert id == stray.id
      refute Mydia.Repo.get(MediaFile, stray.id)
      assert Mydia.Repo.get(MediaFile, own.id)
      assert_enqueued(worker: Mydia.Jobs.RematchImportCandidates)
    end

    test "refuses to send every file of a group" do
      {_movie, own, stray} = misfiled_movie()

      assert %{returned: [], failed: [], aborted: aborted} =
               Prune.send_to_review([own.id, stray.id], "42")

      assert Enum.sort(aborted) ==
               Enum.sort([{own.id, :would_leave_no_file}, {stray.id, :would_leave_no_file}])

      assert Mydia.Repo.get(MediaFile, own.id)
      assert Mydia.Repo.get(MediaFile, stray.id)
    end

    test "refuses a file that is not in a refused group" do
      {_episode, [file | _]} = episode_with(@same_episode_twice, 1320.0)

      assert %{returned: [], aborted: [{id, :not_in_any_group}]} =
               Prune.send_to_review([file.id], "42")

      assert id == file.id
      assert Mydia.Repo.get(MediaFile, file.id)
    end

    test "reports a file it could not send and still sends the others" do
      {movie, _own, stray} = misfiled_movie()
      lp = library_path_fixture(%{type: "movies"})

      legacy =
        media_file_fixture(%{
          media_item_id: movie.id,
          library_path_id: lp.id,
          relative_path: "Legacy/legacy.mkv",
          metadata: %{"container" => "mkv", "duration" => 9000.0}
        })

      # The legacy shape (no library path, no relative path) is only reachable
      # by bypassing MediaFile.changeset/2.
      Mydia.Repo.update_all(from(f in MediaFile, where: f.id == ^legacy.id),
        set: [library_path_id: nil, relative_path: nil]
      )

      assert %{returned: [%MediaFile{id: returned_id}], failed: [{failed_id, :no_library_path}]} =
               Prune.send_to_review([stray.id, legacy.id], "42")

      assert returned_id == stray.id
      assert failed_id == legacy.id
    end
  end
end
