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

  import Ecto.Query
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

  # The load-bearing regression guard for `ImportGroups.change_match/2`:
  # `ingest_member/2` builds each file's match from `candidate.provider_id ||
  # group.provider_id` -- candidate first. If change_match/2 only rewrote the
  # group's own row and left each member's stale candidate in place, this
  # worker would still commit the *wrong* match, and a reviewer's correction
  # would silently do nothing.
  #
  # The wrong candidate is deliberately seeded with provider_id "999999" --
  # `MetadataStubProvider.missing_id/0`, the id its `fetch_by_id/3` always
  # fails on. That makes the two outcomes cleanly distinguishable: if the
  # member candidate never got corrected, `FileIngest.ingest/3` still tries
  # to fetch the missing id, the member stays unresolved, and the group never
  # reaches "applied" at all.
  test "the worker commits a human-corrected match, not the stale candidate it replaced" do
    lp = library_path_fixture(%{type: "series", path: "/media/WrongMatch"})
    correct_title = MetadataStubProvider.series_title()
    correct_id = MetadataStubProvider.series_tvdb_id()

    for n <- 1..2 do
      file =
        orphaned_media_file_fixture(%{
          library_path_id: lp.id,
          relative_path: "Wrong Folder (2018)/Season 01/ep#{n}.mkv"
        })

      %Mydia.Library.MatchCandidate{}
      |> Mydia.Library.MatchCandidate.changeset(%{
        media_file_id: file.id,
        rank: 0,
        provider_id: to_string(MetadataStubProvider.missing_id()),
        provider_type: "tvdb",
        title: "Totally Wrong Show",
        media_type: "tv_show",
        confidence: 0.703,
        parsed_info: %{"season" => 1, "episodes" => [n]}
      })
      |> Repo.insert!()
    end

    {:ok, _} = ImportGroups.upsert_for_library(lp)
    group = Repo.get_by!(ImportGroup, library_path_id: lp.id)
    assert group.provider_id == to_string(MetadataStubProvider.missing_id())

    assert {:ok, _} =
             ImportGroups.change_match(group.id, %{
               provider_id: correct_id,
               provider_type: :tvdb,
               title: correct_title,
               year: 2008,
               media_type: :tv_show
             })

    scope = lp.id |> SelectionScope.new() |> SelectionScope.select_all_matching(%{band: :ready})
    assert {:ok, 1} = ImportGroups.accept(scope)

    assert :ok = perform_job(ApplyImportGroups, %{"library_path_id" => lp.id})

    reloaded_group = Repo.get_by!(ImportGroup, library_path_id: lp.id)
    assert reloaded_group.status == "applied"
    assert reloaded_group.unresolved_count == 0

    media_item = Repo.get_by!(Mydia.Media.MediaItem, title: correct_title)
    assert media_item.tvdb_id == correct_id

    linked_files =
      Mydia.Library.MediaFile
      |> where([f], f.library_path_id == ^lp.id)
      |> Repo.all()

    assert length(linked_files) == 2
    assert Enum.all?(linked_files, & &1.episode_id)
  end

  # Regression: `provider_type/2` used to call `String.to_existing_atom/1` on
  # this free-text column. A value the VM had never interned as an atom
  # raised `ArgumentError`, which `safe_ingest/2` caught -- so the member
  # never got a fair shot at ingesting even with a perfectly valid
  # provider_id, and the group sat "accepted" until `max_attempts` exhausted
  # it. Proves the fallback by using a *real* tvdb id (resolvable by the
  # stub) alongside a provider_type value guaranteed to never already be an
  # atom: the group must still reach "applied", which only happens if
  # provider_type/2 maps the garbage value to :tvdb instead of raising on it.
  test "an unrecognized provider_type on the candidate falls back instead of raising" do
    lp = library_path_fixture(%{type: "series", path: "/media/BogusProviderType"})
    title = MetadataStubProvider.series_title()
    series_id = MetadataStubProvider.series_tvdb_id() |> to_string()
    bogus_provider_type = "not_a_real_provider_#{System.unique_integer([:positive])}"

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
        provider_type: bogus_provider_type,
        title: title,
        media_type: "tv_show",
        confidence: 1.0,
        parsed_info: %{"season" => 1, "episodes" => [n]}
      })
      |> Repo.insert!()
    end

    {:ok, _} = ImportGroups.upsert_for_library(lp)

    scope = lp.id |> SelectionScope.new() |> SelectionScope.select_all_matching(%{band: :ready})
    assert {:ok, 1} = ImportGroups.accept(scope)

    assert :ok = perform_job(ApplyImportGroups, %{"library_path_id" => lp.id})

    group = Repo.get_by!(ImportGroup, library_path_id: lp.id)
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
  # `drain/2` calls, not one.
  test "drains a group across multiple pages when member_page caps below its size" do
    series_lp = library_path_fixture(%{type: "series", path: "/media/TV"})
    series_title = MetadataStubProvider.series_title()
    series_id = MetadataStubProvider.series_tvdb_id() |> to_string()

    episodes = [
      {"Season 01/S01E01.mkv", 1, 1},
      {"Season 01/S01E02.mkv", 1, 2},
      {"Season 02/S02E01.mkv", 2, 1}
    ]

    for {rel_path, season, ep} <- episodes do
      file =
        orphaned_media_file_fixture(%{
          library_path_id: series_lp.id,
          relative_path: "#{series_title} (2020)/#{rel_path}"
        })

      %Mydia.Library.MatchCandidate{}
      |> Mydia.Library.MatchCandidate.changeset(%{
        media_file_id: file.id,
        rank: 0,
        provider_id: series_id,
        provider_type: "tvdb",
        title: series_title,
        media_type: "tv_show",
        confidence: 1.0,
        parsed_info: %{"season" => season, "episodes" => [ep]}
      })
      |> Repo.insert!()
    end

    {:ok, _} = ImportGroups.upsert_for_library(series_lp)

    scope =
      series_lp.id |> SelectionScope.new() |> SelectionScope.select_all_matching(%{band: :ready})

    assert {:ok, 1} = ImportGroups.accept(scope)

    assert :ok =
             perform_job(ApplyImportGroups, %{
               "library_path_id" => series_lp.id,
               "member_page" => 2
             })

    group = Repo.get_by!(ImportGroup, library_path_id: series_lp.id)
    assert group.status == "applied"
    assert group.unresolved_count == 0
  end

  # A group with no candidate at all has no provider_id, which now keeps it
  # out of `accepted_groups/1` entirely (see the test below): the worker never
  # attempts it, so there is nothing left here to make zero progress on. This
  # used to reach `drain/2`'s no-progress guard and come back `{:error, _}`,
  # burning the retry budget on a group that could never succeed -- exactly
  # the interaction the `not is_nil(g.provider_id)` filter in
  # `accepted_groups/1` closes off. `accept/1` can still mark a `:no_match`
  # group "accepted" (a manual "select all" that spans every band, as here),
  # so this is still worth covering end to end through `accept/1` and not just
  # via the focused seed below.
  test "an accepted group with no provider match is skipped, not retried forever" do
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

    assert :ok = perform_job(ApplyImportGroups, %{"library_path_id" => lp.id})

    group = Repo.get_by!(ImportGroup, library_path_id: lp.id)
    assert group.status == "accepted"
    assert group.unresolved_count == 1
  end

  # Focused regression guard for the interaction above: a group can reach
  # `status: "accepted"` with `provider_id: nil` through `accept/1` (see the
  # test above) or through `ImportGroups.create_local_show/1` leaving a
  # partially-linked group behind -- except create_local_show/1 now always
  # marks its group "applied", specifically so it can never hand this worker
  # an "accepted" group with no provider match. This test seeds that state
  # directly, bypassing both call sites, so it stays a guard against the
  # underlying interaction even if a future caller reintroduces it some other
  # way. Without the `not is_nil(g.provider_id)` filter in
  # `accepted_groups/1`, this group would be swept up, handed to `FileIngest`
  # with a nil `provider_id` on its only member, fail to link, and return
  # `{:error, _}` from `perform/1`.
  test "the worker never picks up an accepted group with no provider match", %{
    library_path: lp
  } do
    group =
      %ImportGroup{}
      |> ImportGroup.changeset(%{
        library_path_id: lp.id,
        anchor_path: "Unidentified",
        cluster_key: "unidentified-direct-seed",
        status: "accepted",
        provider_id: nil,
        file_count: 1,
        unresolved_count: 1
      })
      |> Repo.insert!()

    # A real, unresolved member is what makes this a genuine regression guard:
    # with no member at all `drain/2` sees zero remaining immediately and
    # marks the group "applied" regardless of the filter under test (the same
    # shape as "a group whose files vanished still completes" above), which
    # would pass even without the fix.
    file =
      orphaned_media_file_fixture(%{
        library_path_id: lp.id,
        relative_path: "Unidentified/reel.mkv"
      })

    Repo.update_all(from(f in Mydia.Library.MediaFile, where: f.id == ^file.id),
      set: [import_group_id: group.id]
    )

    assert :ok = perform_job(ApplyImportGroups, %{"library_path_id" => lp.id})

    reloaded = Repo.get!(ImportGroup, group.id)
    assert reloaded.status == "accepted"
    assert reloaded.unresolved_count == 1
  end

  # A locally-created group (`ImportGroups.create_local_show/1`) carries a
  # synthetic `provider_id` (`"local-" <> item.id`) precisely so a second call
  # against it is refused -- but that same synthetic id would otherwise slip
  # past `accepted_groups/1`'s `not is_nil(g.provider_id)` filter and get
  # handed to `FileIngest`, which recognises no provider with that id. This is
  # the regression guard for that: a group with a non-nil `provider_id` but
  # `provider_type: "local"` must still never be picked up.
  test "the worker never picks up an accepted group created locally", %{library_path: lp} do
    group =
      %ImportGroup{}
      |> ImportGroup.changeset(%{
        library_path_id: lp.id,
        anchor_path: "LocalShow",
        cluster_key: "local-show-direct-seed",
        status: "accepted",
        provider_type: "local",
        provider_id: "local-deadbeef",
        file_count: 1,
        unresolved_count: 1
      })
      |> Repo.insert!()

    file =
      orphaned_media_file_fixture(%{
        library_path_id: lp.id,
        relative_path: "LocalShow/reel.mkv"
      })

    Repo.update_all(from(f in Mydia.Library.MediaFile, where: f.id == ^file.id),
      set: [import_group_id: group.id]
    )

    assert :ok = perform_job(ApplyImportGroups, %{"library_path_id" => lp.id})

    reloaded = Repo.get!(ImportGroup, group.id)
    assert reloaded.status == "accepted"
    assert reloaded.unresolved_count == 1
  end

  # Restores the coverage the previous two tests lost for `drain/2`'s
  # no-progress-halt guard: that guard was a Task 11 review finding
  # ("without it a group whose members can never link would spin forever"),
  # and the test that used to reach it did so through a provider-less group --
  # exactly the shape `accepted_groups/1`'s new filter now excludes before
  # `drain/2` ever runs. The guard still matters for a provider-*matched*
  # group, so this reaches it that way instead: two members link for real
  # against the stub (giving the group a genuine `provider_id`, so it survives
  # the filter), and a third has no candidate at all -- the cheapest way to
  # make a member permanently unlinkable, since `ingest_member/2`'s
  # `candidate: nil` clause is a deliberate no-op. The first `drain/2` pass
  # makes progress (2 of 3 link) and recurses; the second makes none and
  # halts, so this also exercises the recursive branch on the way to the
  # no-progress one.
  test "a page that makes partial progress still halts once the rest can't link", %{
    library_path: lp
  } do
    title = MetadataStubProvider.series_title()

    stuck_file =
      orphaned_media_file_fixture(%{
        library_path_id: lp.id,
        relative_path: "#{title}/Season 01/ep3.mkv"
      })

    {:ok, _} = ImportGroups.upsert_for_library(lp)

    scope = lp.id |> SelectionScope.new() |> SelectionScope.select_all_matching(%{band: :all})
    assert {:ok, 1} = ImportGroups.accept(scope)

    group = Repo.get_by!(ImportGroup, library_path_id: lp.id)
    assert group.provider_id

    assert {:error, _reason} = perform_job(ApplyImportGroups, %{"library_path_id" => lp.id})

    reloaded = Repo.get_by!(ImportGroup, library_path_id: lp.id)
    assert reloaded.status == "accepted"
    assert reloaded.unresolved_count == 1

    refute Repo.reload!(stuck_file).episode_id
  end
end
