defmodule Mydia.Jobs.ApplyImportGroupsTest do
  use Mydia.DataCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.ImportGroups
  alias Mydia.Jobs.ApplyImportGroups
  alias Mydia.Library.{ImportGroup, SelectionScope}
  alias Mydia.Repo

  setup do
    lp = library_path_fixture(%{type: "series", path: "/media/Series"})

    for n <- 1..3 do
      file =
        orphaned_media_file_fixture(%{
          library_path_id: lp.id,
          relative_path: "Cornemuse (1999)/Season 02/ep#{n}.mkv"
        })

      %Mydia.Library.MatchCandidate{}
      |> Mydia.Library.MatchCandidate.changeset(%{
        media_file_id: file.id,
        rank: 0,
        provider_id: "277262",
        provider_type: "tvdb",
        title: "Cornemuse",
        media_type: "tv_show",
        confidence: 1.0,
        parsed_info: %{"season" => 2, "episodes" => [n]}
      })
      |> Repo.insert!()
    end

    {:ok, _} = ImportGroups.upsert_for_library(lp)

    {:ok, library_path: lp}
  end

  test "accept marks the selection and enqueues one job", %{library_path: lp} do
    scope = lp.id |> SelectionScope.new() |> SelectionScope.select_all_matching(%{band: :ready})

    assert {:ok, 1} = ImportGroups.accept(scope)
    assert Repo.one!(ImportGroup).status == "accepted"
    assert Repo.one!(ImportGroup).decided_at

    assert_enqueued(worker: ApplyImportGroups, args: %{"library_path_id" => lp.id})
  end

  test "accepting a group already accepted by someone else is a no-op", %{library_path: lp} do
    scope = lp.id |> SelectionScope.new() |> SelectionScope.select_all_matching(%{band: :ready})

    assert {:ok, 1} = ImportGroups.accept(scope)
    assert {:ok, 0} = ImportGroups.accept(scope)
  end

  test "the worker moves accepted groups to applied", %{library_path: lp} do
    scope = lp.id |> SelectionScope.new() |> SelectionScope.select_all_matching(%{band: :ready})
    {:ok, 1} = ImportGroups.accept(scope)

    assert :ok = perform_job(ApplyImportGroups, %{"library_path_id" => lp.id})

    group = Repo.one!(ImportGroup)
    assert group.status == "applied"
    assert group.unresolved_count == 0
  end

  test "a group whose files vanished still completes", %{library_path: lp} do
    scope = lp.id |> SelectionScope.new() |> SelectionScope.select_all_matching(%{band: :ready})
    {:ok, 1} = ImportGroups.accept(scope)

    Repo.delete_all(Mydia.Library.MediaFile)

    assert :ok = perform_job(ApplyImportGroups, %{"library_path_id" => lp.id})
    assert Repo.one!(ImportGroup).status == "applied"
  end

  test "ignore marks without enqueueing", %{library_path: lp} do
    scope = lp.id |> SelectionScope.new() |> SelectionScope.select_all_matching(%{band: :ready})

    assert {:ok, 1} = ImportGroups.ignore(scope)
    assert Repo.one!(ImportGroup).status == "ignored"
    refute_enqueued(worker: ApplyImportGroups)
  end
end
