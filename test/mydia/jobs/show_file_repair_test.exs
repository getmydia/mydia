defmodule Mydia.Jobs.ShowFileRepairTest do
  use Mydia.DataCase, async: true
  use Oban.Testing, repo: Mydia.Repo

  import Mydia.Factory

  alias Mydia.ImportCandidates
  alias Mydia.Jobs.ShowFileRepair
  alias Mydia.Library.MediaFile
  alias Mydia.Repo

  # The shape MediaFile.changeset/2 refuses: a TV file attached straight to its
  # show. Only a legacy row can have it, so it is inserted as a bare struct.
  defp show_level_file(show, library_path, relative_path, attrs \\ %{}) do
    %MediaFile{
      media_item_id: show.id,
      library_path_id: library_path.id,
      relative_path: relative_path,
      size: 1_000_000
    }
    |> struct!(attrs)
    |> Repo.insert!()
  end

  setup do
    show = insert(:tv_show, %{title: "Lantern Coast", year: 2019, tvdb_id: 900_002})
    library_path = insert(:library_path, %{type: :series})
    episode = insert(:episode, %{media_item: show, season_number: 1, episode_number: 1})

    {:ok, show: show, library_path: library_path, episode: episode}
  end

  test "re-links a file whose name names an episode the show has", %{
    show: show,
    library_path: library_path,
    episode: episode
  } do
    file = show_level_file(show, library_path, "Lantern Coast/Season 01/Lantern.Coast.S01E01.mkv")

    assert {:ok, %{relinked: 1, demoted: 0, skipped: 0}} = ShowFileRepair.run()

    reloaded = Repo.get!(MediaFile, file.id)
    assert reloaded.episode_id == episode.id
    assert is_nil(reloaded.media_item_id)
  end

  test "demotes a file that names no episode to an import candidate", %{
    show: show,
    library_path: library_path
  } do
    relative = "Lantern Coast/Lantern.Coast.Pilot.Reshoot.mkv"
    file = show_level_file(show, library_path, relative)

    assert {:ok, %{relinked: 0, demoted: 1, skipped: 0}} = ShowFileRepair.run()

    assert is_nil(Repo.get(MediaFile, file.id))

    candidate = ImportCandidates.get_by_path(library_path.id, relative)
    assert candidate.media_type == "tv_show"
    assert {candidate.provider_type, candidate.provider_id} == {"tvdb", "900002"}
  end

  test "leaves trashed rows and show-level extras alone", %{
    show: show,
    library_path: library_path
  } do
    trashed =
      show_level_file(show, library_path, "Lantern Coast/Lantern.Coast.Old.Cut.mkv", %{
        trashed_at: ~U[2026-09-01 00:00:00Z]
      })

    # Named like an episode on purpose: the re-link must skip extras too.
    extra =
      show_level_file(show, library_path, "Lantern Coast/Lantern.Coast.S01E01.Featurette.mkv", %{
        extra_kind: :other
      })

    assert {:ok, %{relinked: 0, demoted: 0, skipped: 0}} = ShowFileRepair.run()

    assert Repo.get!(MediaFile, trashed.id).media_item_id == show.id

    reloaded_extra = Repo.get!(MediaFile, extra.id)
    assert reloaded_extra.media_item_id == show.id
    assert is_nil(reloaded_extra.episode_id)
  end

  test "a second run finds nothing to do", %{show: show, library_path: library_path} do
    show_level_file(show, library_path, "Lantern Coast/Season 01/Lantern.Coast.S01E01.mkv")
    show_level_file(show, library_path, "Lantern Coast/Lantern.Coast.Pilot.Reshoot.mkv")

    assert {:ok, %{relinked: 1, demoted: 1}} = ShowFileRepair.run()
    assert {:ok, %{relinked: 0, demoted: 0, skipped: 0}} = ShowFileRepair.run()
  end

  test "walks every affected show across page boundaries", %{library_path: library_path} do
    for n <- 1..3 do
      show = insert(:tv_show, %{title: "Harbor Lights #{n}"})
      show_level_file(show, library_path, "Harbor Lights #{n}/Harbor.Lights.Reshoot.#{n}.mkv")
    end

    assert {:ok, %{demoted: 3}} = ShowFileRepair.run(batch_size: 1)
  end

  test "perform/1 runs the repair", %{show: show, library_path: library_path} do
    file = show_level_file(show, library_path, "Lantern Coast/Lantern.Coast.Pilot.Reshoot.mkv")

    assert :ok = perform_job(ShowFileRepair, %{})
    assert is_nil(Repo.get(MediaFile, file.id))
  end

  test "fails a row whose staging errors, so Oban retries it", %{
    show: show,
    library_path: library_path
  } do
    # An empty relative_path is not nil, so it reaches the transaction, and
    # ImportCandidate.changeset/2's validate_required([:relative_path, ...])
    # rejects it there. That is a staging failure the row should be retried
    # for, unlike the no-library-path/no-relative-path shapes above.
    file = show_level_file(show, library_path, "")

    assert {:ok, %{relinked: 0, demoted: 0, skipped: 0, failed: 1}} = ShowFileRepair.run()

    assert %MediaFile{} = Repo.get!(MediaFile, file.id)

    assert {:error, {:show_file_repair_failed, 1}} = perform_job(ShowFileRepair, %{})
  end
end
