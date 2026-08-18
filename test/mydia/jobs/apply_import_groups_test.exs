defmodule Mydia.Jobs.ApplyImportGroupsTest do
  @moduledoc """
  Exercises the real link path (`FileIngest.ingest/3` -> `MetadataEnricher.enrich/2`)
  rather than stopping at the `:candidate` write, so `Mydia.MetadataStub` swaps in
  `Mydia.MetadataStubProvider` for the duration of the test instead of hitting the
  real metadata-relay. That is the same seam `Jobs.ImportRunUnattendedTest` uses for
  the same reason: the link path fans out over fetch_by_id and fetch_season, and the
  stub catalog is self-consistent across both. `Provider.Registry` is a process-global
  Agent, hence `async: false`.

  The stub's catalog is deliberately tiny: one series (`series_tvdb_id/0`) with a
  single season carrying two episodes. Fixtures below target that season/episode
  range rather than the three-file spread an arbitrary real show would allow.
  """
  use Mydia.DataCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  import Mydia.MediaFixtures
  import Mydia.MetadataStub
  import Mydia.SettingsFixtures

  alias Mydia.ImportGroups
  alias Mydia.Jobs.ApplyImportGroups
  alias Mydia.Library.{ImportGroup, SelectionScope}
  alias Mydia.MetadataStubProvider
  alias Mydia.Repo

  setup :setup_metadata_stub

  setup do
    lp = library_path_fixture(%{type: "series", path: "/media/Series"})
    title = MetadataStubProvider.series_title()
    series_id = MetadataStubProvider.series_tvdb_id() |> to_string()

    for n <- 1..2 do
      file =
        orphaned_media_file_fixture(%{
          library_path_id: lp.id,
          relative_path: "#{title}/Season 01/ep#{n}.mkv"
        })

      %Mydia.Library.MatchCandidate{}
      |> Mydia.Library.MatchCandidate.changeset(%{
        media_file_id: file.id,
        rank: 0,
        provider_id: series_id,
        provider_type: "tvdb",
        title: title,
        media_type: "tv_show",
        confidence: 1.0,
        parsed_info: %{"season" => 1, "episodes" => [n]}
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

  # Every other test's group has 1-2 members, far under `@member_page`, so
  # `drain/2`'s recursive branch never runs there. This test forces it with a
  # tiny `member_page` job arg instead of inserting a thousand rows: three
  # resolvable members, paged two at a time, so applying the group takes two
  # `drain/2` calls, not one. Movie files are used (rather than a second TV
  # season) because a movie's association is per-file, not per-episode, so
  # three separate files can all resolve against the stub's single movie
  # without running into the stub's two-episode-per-season ceiling.
  test "drains a group across multiple pages when member_page caps below its size" do
    movie_lp = library_path_fixture(%{type: "movies", path: "/media/Movies"})
    movie_title = MetadataStubProvider.movie_title()
    movie_id = MetadataStubProvider.movie_tmdb_id() |> to_string()

    for n <- 1..3 do
      file =
        orphaned_media_file_fixture(%{
          library_path_id: movie_lp.id,
          relative_path: "#{movie_title} (1999)/copy#{n}.mkv"
        })

      %Mydia.Library.MatchCandidate{}
      |> Mydia.Library.MatchCandidate.changeset(%{
        media_file_id: file.id,
        rank: 0,
        provider_id: movie_id,
        provider_type: "tmdb",
        title: movie_title,
        media_type: "movie",
        confidence: 1.0,
        parsed_info: %{}
      })
      |> Repo.insert!()
    end

    {:ok, _} = ImportGroups.upsert_for_library(movie_lp)

    scope =
      movie_lp.id |> SelectionScope.new() |> SelectionScope.select_all_matching(%{band: :ready})

    assert {:ok, 1} = ImportGroups.accept(scope)

    assert :ok =
             perform_job(ApplyImportGroups, %{
               "library_path_id" => movie_lp.id,
               "member_page" => 2
             })

    group = Repo.get_by!(ImportGroup, library_path_id: movie_lp.id)
    assert group.status == "applied"
    assert group.unresolved_count == 0
  end

  # A member with no candidate at all can never link (`ingest_member/2`'s
  # `candidate: nil` clause is a deliberate no-op), so this is the cheapest way
  # to make a page make zero progress. Without the no-progress guard, `drain/2`
  # would refetch the same unresolved member forever.
  test "a page that links nothing halts instead of spinning" do
    lp = library_path_fixture(%{type: "movies", path: "/media/NoMatch"})

    orphaned_media_file_fixture(%{
      library_path_id: lp.id,
      relative_path: "Unidentified (2020)/reel.mkv"
    })

    {:ok, _} = ImportGroups.upsert_for_library(lp)

    # No candidate means no provider_id, which puts the group in :no_match
    # rather than :ready, so the selection has to cover every band here.
    scope = lp.id |> SelectionScope.new() |> SelectionScope.select_all_matching(%{band: :all})
    assert {:ok, 1} = ImportGroups.accept(scope)

    assert {:error, _reason} = perform_job(ApplyImportGroups, %{"library_path_id" => lp.id})

    group = Repo.get_by!(ImportGroup, library_path_id: lp.id)
    assert group.status == "accepted"
    assert group.unresolved_count == 1
  end
end
