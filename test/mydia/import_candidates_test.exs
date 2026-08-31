defmodule Mydia.ImportCandidatesTest do
  # Some describe blocks swap in Mydia.MetadataStubProvider, a process-global
  # registration -- see Mydia.MetadataStub's moduledoc for why every test
  # using it (and therefore this whole module) must run synchronously.
  use Mydia.DataCase, async: false

  import Ecto.Query
  import Mydia.MediaFixtures
  import Mydia.MetadataStub
  import Mydia.SettingsFixtures

  alias Mydia.ImportCandidates
  alias Mydia.Library.{ImportCandidate, ImportCandidateGroup, MediaFile, SelectionScope}
  alias Mydia.Repo

  defp seed_group(lp, anchor_key, count, attrs \\ %{}) do
    for n <- 1..count do
      import_candidate_fixture(
        Map.merge(
          %{
            library_path_id: lp.id,
            anchor_key: anchor_key,
            relative_path: "#{anchor_key}/file-#{n}.mkv"
          },
          Map.new(attrs)
        )
      )
    end
  end

  describe "page/2 keyset paging" do
    test "keyset paging breaks equal file counts by anchor_key" do
      lp = library_path_fixture(%{type: "series"})
      seed_group(lp, "alpha", 2)
      seed_group(lp, "bravo", 2)
      seed_group(lp, "charlie", 1)

      {[first], cursor} = ImportCandidates.page(lp.id, limit: 1)
      {[second], next_cursor} = ImportCandidates.page(lp.id, limit: 1, after: cursor)
      {[third], nil} = ImportCandidates.page(lp.id, limit: 1, after: next_cursor)

      assert Enum.map([first, second, third], & &1.anchor_key) == ["alpha", "bravo", "charlie"]
    end

    test "matches a literal percent and underscore without them acting as wildcards" do
      lp = library_path_fixture(%{type: "series"})
      seed_group(lp, "100% Wolf", 2)
      seed_group(lp, "1002 Dalmatians", 1)
      seed_group(lp, "abc_def", 1)
      seed_group(lp, "abcxdef", 1)

      {percent_hits, _cursor} = ImportCandidates.page(lp.id, q: "100%")
      assert Enum.map(percent_hits, & &1.anchor_key) == ["100% Wolf"]

      {underscore_hits, _cursor} = ImportCandidates.page(lp.id, q: "abc_def")
      assert Enum.map(underscore_hits, & &1.anchor_key) == ["abc_def"]
    end
  end

  test "dismissal survives a fresh import upsert" do
    candidate = import_candidate_fixture()

    scope =
      candidate.library_path_id
      |> SelectionScope.new()
      |> SelectionScope.select_page([candidate.anchor_key])

    assert {:ok, 1} = ImportCandidates.dismiss(scope)

    assert {:ok, _} =
             ImportCandidates.upsert(
               Map.from_struct(candidate)
               |> Map.take([:library_path_id, :relative_path, :anchor_key, :size, :discovered_at])
             )

    assert Repo.reload!(candidate).dismissed_at
    assert {[], nil} = ImportCandidates.page(candidate.library_path_id)
  end

  describe "band/1" do
    defp group(attrs) do
      Map.merge(
        %ImportCandidateGroup{
          id: "g",
          anchor_key: "g",
          library_path_id: Ecto.UUID.generate(),
          file_count: 1
        },
        Map.new(attrs)
      )
    end

    test "ready at or above the threshold with a single provider" do
      assert ImportCandidates.band(group(provider_id: "1", min_confidence: 0.95)) == :ready
      assert ImportCandidates.band(group(provider_id: "1", min_confidence: 0.85)) == :ready
    end

    test "needs attention below the threshold" do
      assert ImportCandidates.band(group(provider_id: "1", min_confidence: 0.70)) ==
               :needs_attention
    end

    test "no match when no candidate resolved a provider" do
      assert ImportCandidates.band(group(provider_id: nil, min_confidence: nil)) == :no_match
    end

    test "disagreement (nil min_confidence with a provider present) forces needs attention" do
      assert ImportCandidates.band(group(provider_id: "1", min_confidence: nil)) ==
               :needs_attention
    end

    test "a local provider_type is never ready, whatever its confidence" do
      g = group(provider_id: "local-abc", provider_type: "local", min_confidence: 1.0)
      assert ImportCandidates.band(g) == :needs_attention
    end
  end

  describe "group disagreement" do
    test "candidates disagreeing on provider_id null out min_confidence and land in needs_attention" do
      lp = library_path_fixture(%{type: "series"})

      import_candidate_fixture(%{
        library_path_id: lp.id,
        anchor_key: "show",
        relative_path: "show/a.mkv",
        provider_id: "1",
        confidence: 1.0
      })

      import_candidate_fixture(%{
        library_path_id: lp.id,
        anchor_key: "show",
        relative_path: "show/b.mkv",
        provider_id: "2",
        confidence: 1.0
      })

      assert {[group], nil} = ImportCandidates.page(lp.id)
      assert group.provider_count == 2
      assert group.min_confidence == nil
      assert ImportCandidates.band(group) == :needs_attention

      {ready, _cursor} = ImportCandidates.page(lp.id, band: :ready)
      assert ready == []
    end
  end

  describe "a local-marked group surfaces as needs_attention through the SQL path, not just band/1" do
    # Regression: a `provider_type: "local"` group with a single agreeing
    # provider at or above the threshold is excluded from `:ready` by the
    # local carve-out, but is neither disagreeing nor low-confidence, so a
    # `:needs_attention` predicate written as its own independent condition
    # (rather than the complement of the other two) missed it entirely --
    # invisible to band_counts/1's total and to every band-filtered read.
    # `band/1` (a pure function over an already-materialized struct) got this
    # right from the start; this proves the SQL aggregate path agrees.
    test "count_by_status/2, band_counts/1, and page(band: :needs_attention) all see it" do
      lp = library_path_fixture(%{type: "series"})

      import_candidate_fixture(%{
        library_path_id: lp.id,
        anchor_key: "local-show",
        provider_id: "local-abc",
        provider_type: "local",
        confidence: 1.0
      })

      assert ImportCandidates.count_by_status(lp.id, "pending") == 1

      assert %{ready: 0, needs_attention: 1, no_match: 0, total: 1} =
               ImportCandidates.band_counts(lp.id)

      {needs_attention, _cursor} = ImportCandidates.page(lp.id, band: :needs_attention)
      assert Enum.map(needs_attention, & &1.anchor_key) == ["local-show"]

      {ready, _cursor} = ImportCandidates.page(lp.id, band: :ready)
      assert ready == []

      {no_match, _cursor} = ImportCandidates.page(lp.id, band: :no_match)
      assert no_match == []
    end
  end

  describe "a matched group with NULL confidence stays visible in the SQL bands" do
    test "band counts, paging, and a filter selection all classify it as needs_attention" do
      lp = library_path_fixture(%{type: "series"})

      import_candidate_fixture(%{
        library_path_id: lp.id,
        anchor_key: "unknown-confidence",
        provider_id: "1234",
        provider_type: "tvdb",
        confidence: nil
      })

      assert %{ready: 0, needs_attention: 1, no_match: 0, total: 1} =
               ImportCandidates.band_counts(lp.id)

      assert {[group], nil} = ImportCandidates.page(lp.id, band: :needs_attention)
      assert group.anchor_key == "unknown-confidence"

      scope =
        lp.id
        |> SelectionScope.new()
        |> SelectionScope.select_all_matching(%{band: :needs_attention})

      assert SelectionScope.count(scope) == 1
    end
  end

  describe "band_counts/1, count_by_status/2, and count_pending/0" do
    test "band_counts/1 partitions pending groups by band" do
      lp = library_path_fixture(%{type: "series"})

      import_candidate_fixture(%{
        library_path_id: lp.id,
        anchor_key: "ready",
        provider_id: "1",
        provider_type: "tvdb",
        confidence: 1.0
      })

      import_candidate_fixture(%{
        library_path_id: lp.id,
        anchor_key: "attn",
        provider_id: "1",
        provider_type: "tvdb",
        confidence: 0.5
      })

      import_candidate_fixture(%{library_path_id: lp.id, anchor_key: "none"})

      assert %{ready: 1, needs_attention: 1, no_match: 1, total: 3} =
               ImportCandidates.band_counts(lp.id)
    end

    test "count_by_status/2 counts dismissed and undismissed anchors separately, scoped to the library" do
      lp = library_path_fixture(%{type: "series"})
      other_lp = library_path_fixture(%{type: "series"})

      import_candidate_fixture(%{library_path_id: lp.id, anchor_key: "active"})

      import_candidate_fixture(%{
        library_path_id: lp.id,
        anchor_key: "ignored",
        dismissed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

      import_candidate_fixture(%{
        library_path_id: other_lp.id,
        anchor_key: "ignored-elsewhere",
        dismissed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

      assert ImportCandidates.count_by_status(lp.id, "pending") == 1
      assert ImportCandidates.count_by_status(lp.id, "ignored") == 1
    end

    test "count_pending/0 counts undismissed groups across libraries, not files" do
      lp = library_path_fixture(%{type: "series"})
      seed_group(lp, "alpha", 3)

      other_lp = library_path_fixture(%{type: "movies"})
      seed_group(other_lp, "beta", 1)

      assert ImportCandidates.count_pending() == 2
    end
  end

  describe "dismiss/1 and restore/1" do
    test "dismiss stamps dismissed_at on every undismissed candidate in the selected anchors" do
      lp = library_path_fixture(%{type: "series"})
      seed_group(lp, "alpha", 2)
      seed_group(lp, "bravo", 1)

      scope = lp.id |> SelectionScope.new() |> SelectionScope.select_page(["alpha"])

      assert {:ok, 1} = ImportCandidates.dismiss(scope)

      assert {[bravo], nil} = ImportCandidates.page(lp.id)
      assert bravo.anchor_key == "bravo"

      assert {[alpha], nil} = ImportCandidates.page(lp.id, status: "ignored")
      assert alpha.anchor_key == "alpha"
    end

    test "restore clears dismissed_at only for the selected dismissed anchors" do
      lp = library_path_fixture(%{type: "series"})
      seed_group(lp, "alpha", 2)
      seed_group(lp, "bravo", 1)

      dismiss_scope =
        lp.id |> SelectionScope.new() |> SelectionScope.select_page(["alpha", "bravo"])

      assert {:ok, 2} = ImportCandidates.dismiss(dismiss_scope)

      restore_scope =
        lp.id |> SelectionScope.new("ignored") |> SelectionScope.select_page(["alpha"])

      assert {:ok, 1} = ImportCandidates.restore(restore_scope)

      assert {[group], nil} = ImportCandidates.page(lp.id)
      assert group.anchor_key == "alpha"

      assert {[still_ignored], nil} = ImportCandidates.page(lp.id, status: "ignored")
      assert still_ignored.anchor_key == "bravo"
    end

    test "a selection round-trips through to_args/from_args and still selects the same anchors" do
      lp = library_path_fixture(%{type: "series"})
      seed_group(lp, "alpha", 1)
      seed_group(lp, "bravo", 1)

      scope = lp.id |> SelectionScope.new() |> SelectionScope.select_page(["alpha"])
      restored = scope |> SelectionScope.to_args() |> SelectionScope.from_args()

      assert {:ok, 1} = ImportCandidates.dismiss(restored)

      assert {[bravo], nil} = ImportCandidates.page(lp.id)
      assert bravo.anchor_key == "bravo"
    end
  end

  describe "change_match/3" do
    defp seed_wrong_match_group(lp) do
      for n <- 1..2 do
        import_candidate_fixture(%{
          library_path_id: lp.id,
          anchor_key: "patamuse",
          relative_path: "Patamuse (2018)/Season 01/ep#{n}.mkv",
          provider_id: "9999",
          provider_type: "tvdb",
          title: "The Peter Potamus Show",
          year: 1964,
          media_type: "tv_show",
          confidence: 0.703,
          parsed_info: %{"season" => 1, "episodes" => [n]}
        })
      end
    end

    defp match do
      %{
        provider_id: "12345",
        provider_type: :tvdb,
        title: "Patamuse",
        year: 2018,
        media_type: :tv_show
      }
    end

    test "updates every undismissed candidate's match, preserving each one's parsed season/episode" do
      lp = library_path_fixture(%{type: "series"})
      [first, second] = seed_wrong_match_group(lp)

      assert {:ok, 2} = ImportCandidates.change_match(lp.id, "patamuse", match())

      reloaded_first = Repo.reload!(first)
      reloaded_second = Repo.reload!(second)

      for candidate <- [reloaded_first, reloaded_second] do
        assert candidate.provider_id == "12345"
        assert candidate.provider_type == "tvdb"
        assert candidate.title == "Patamuse"
        assert candidate.year == 2018
        assert candidate.media_type == "tv_show"
        assert candidate.confidence == 1.0
      end

      assert reloaded_first.parsed_info == %{"season" => 1, "episodes" => [1]}
      assert reloaded_second.parsed_info == %{"season" => 1, "episodes" => [2]}

      assert {[group], nil} = ImportCandidates.page(lp.id)
      assert ImportCandidates.band(group) == :ready
    end

    test "does not touch an already-dismissed sibling candidate" do
      lp = library_path_fixture(%{type: "series"})

      active =
        import_candidate_fixture(%{
          library_path_id: lp.id,
          anchor_key: "show",
          relative_path: "show/a.mkv"
        })

      dismissed =
        import_candidate_fixture(%{
          library_path_id: lp.id,
          anchor_key: "show",
          relative_path: "show/b.mkv",
          dismissed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      assert {:ok, 1} = ImportCandidates.change_match(lp.id, "show", match())

      assert Repo.reload!(active).provider_id == "12345"
      refute Repo.reload!(dismissed).provider_id
    end

    test "returns {:error, :not_found} for an anchor with no undismissed candidates" do
      lp = library_path_fixture(%{type: "series"})
      assert {:error, :not_found} = ImportCandidates.change_match(lp.id, "missing", match())
    end
  end

  describe "update_member_episode/3" do
    test "updates season/episode and accepts string inputs" do
      candidate = import_candidate_fixture(%{parsed_info: %{"season" => 1, "episodes" => [1]}})

      assert {:ok, updated} = ImportCandidates.update_member_episode(candidate.id, "3", "12")
      assert updated.parsed_info["season"] == 3
      assert updated.parsed_info["episodes"] == [12]
    end

    test "clears the episode when passed empty strings" do
      candidate = import_candidate_fixture(%{parsed_info: %{"season" => 1, "episodes" => [1]}})

      assert {:ok, cleared} = ImportCandidates.update_member_episode(candidate.id, "", "")
      assert is_nil(cleared.parsed_info["season"])
      assert cleared.parsed_info["episodes"] == []
    end

    test "returns {:error, :not_found} for an unknown candidate id" do
      assert {:error, :not_found} =
               ImportCandidates.update_member_episode(Ecto.UUID.generate(), 1, 1)
    end
  end

  describe "members/2 and member_count/2" do
    test "members/2 caps at the display limit, ordered by relative path; member_count/2 reports the true total" do
      lp = library_path_fixture(%{type: "series"})
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      rows =
        for n <- 1..210 do
          %{
            id: Ecto.UUID.generate(),
            library_path_id: lp.id,
            relative_path: "Show/ep-#{String.pad_leading(Integer.to_string(n), 4, "0")}.mkv",
            anchor_key: "show",
            size: 1,
            attempts: 0,
            discovered_at: now,
            inserted_at: now,
            updated_at: now
          }
        end

      {210, _} = Repo.insert_all(ImportCandidate, rows)

      assert ImportCandidates.member_count(lp.id, "show") == 210

      members = ImportCandidates.members(lp.id, "show")
      assert length(members) == 200
      paths = Enum.map(members, & &1.relative_path)
      assert paths == Enum.sort(paths)
    end
  end

  describe "create_local_show/2" do
    test "creates a show, links numbered candidates, and leaves an unnumbered one visible" do
      lp = library_path_fixture(%{type: "series", path: "/media/Series"})

      numbered =
        for n <- 1..2 do
          import_candidate_fixture(%{
            library_path_id: lp.id,
            anchor_key: "les mots de passe partout",
            relative_path: "Les mots de Passe-Partout (2023)/Season 01/ep#{n}.mkv",
            media_type: "tv_show",
            parsed_info: %{"season" => 1, "episodes" => [n]}
          })
        end

      unnumbered =
        import_candidate_fixture(%{
          library_path_id: lp.id,
          anchor_key: "les mots de passe partout",
          relative_path: "Les mots de Passe-Partout (2023)/Season 01/bonus.mkv",
          media_type: "tv_show",
          parsed_info: %{}
        })

      assert {:ok, item} =
               ImportCandidates.create_local_show(lp.id, "les mots de passe partout")

      assert item.type == "tv_show"
      assert item.title == "Les Mots De Passe Partout"
      # There is no way to recover the year from a normalized anchor key --
      # see create_local_show/2's own note on this trade-off.
      assert item.year == nil
      assert item.metadata_source == nil

      for candidate <- numbered do
        refute Repo.get(ImportCandidate, candidate.id)
      end

      episodes = Repo.all(from(e in Mydia.Media.Episode, where: e.media_item_id == ^item.id))
      assert length(episodes) == 2
      assert Enum.sort(Enum.map(episodes, & &1.episode_number)) == [1, 2]

      linked_files =
        Repo.all(
          from(f in MediaFile, where: not is_nil(f.episode_id) and f.library_path_id == ^lp.id)
        )

      assert length(linked_files) == 2

      assert Repo.get(ImportCandidate, unnumbered.id)

      assert {[group], nil} = ImportCandidates.page(lp.id)
      assert group.anchor_key == "les mots de passe partout"
      assert group.file_count == 1
    end

    test "returns {:error, :not_found} for an anchor with no undismissed candidates" do
      lp = library_path_fixture(%{type: "series"})
      assert {:error, :not_found} = ImportCandidates.create_local_show(lp.id, "missing")
    end

    test "a repeat call against the same anchor is refused instead of creating a second show" do
      lp = library_path_fixture(%{type: "series", path: "/media/Series"})

      import_candidate_fixture(%{
        library_path_id: lp.id,
        anchor_key: "unnumbered only",
        relative_path: "Unnumbered Only/bonus.mkv",
        media_type: "tv_show",
        parsed_info: %{}
      })

      assert {:ok, item} = ImportCandidates.create_local_show(lp.id, "unnumbered only")

      assert {:error, :already_created} =
               ImportCandidates.create_local_show(lp.id, "unnumbered only")

      assert Repo.aggregate(Mydia.Media.MediaItem, :count) == 1
      assert item.title == "Unnumbered Only"

      assert {[group], nil} = ImportCandidates.page(lp.id)
      assert group.anchor_key == "unnumbered only"
      assert ImportCandidates.band(group) == :needs_attention
    end
  end

  describe "clear_for_library/1" do
    test "deletes undismissed candidates and finished run history, preserving dismissed candidates" do
      lp = library_path_fixture(%{type: "movies"})

      kept =
        import_candidate_fixture(%{
          library_path_id: lp.id,
          dismissed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      removed = import_candidate_fixture(%{library_path_id: lp.id})

      {:ok, run} = Mydia.Library.create_import_run(%{library_path_id: lp.id, mode: :review})
      {:ok, _run} = Mydia.Library.update_import_run(run, %{status: :done, phase: :finished})

      assert {:ok, %{candidates: 1}} = ImportCandidates.clear_for_library(lp.id)

      assert Repo.get(ImportCandidate, kept.id)
      refute Repo.get(ImportCandidate, removed.id)
      refute Mydia.Library.last_import_run(lp.id)
    end

    test "refuses to clear while the library is actively scanning" do
      lp = library_path_fixture(%{type: "series"})
      candidate = import_candidate_fixture(%{library_path_id: lp.id})

      {:ok, _run} = Mydia.Library.create_import_run(%{library_path_id: lp.id, mode: :review})

      assert {:error, :active_run} = ImportCandidates.clear_for_library(lp.id)
      assert Repo.get(ImportCandidate, candidate.id)
    end
  end

  describe "rematch/2" do
    test "matches selected candidates and writes results back onto them" do
      lp = library_path_fixture(%{type: "series", path: "/media/Series"})

      candidate =
        import_candidate_fixture(%{
          library_path_id: lp.id,
          anchor_key: "doctor who",
          relative_path: "Doctor Who (2005)/Season 01/Doctor Who - S01E01.mkv",
          parsed_info: %{}
        })

      scope = lp.id |> SelectionScope.new() |> SelectionScope.select_page(["doctor who"])

      assert {:ok, %{files: 1, failures: 0}} =
               ImportCandidates.rematch(scope, matcher: Mydia.Library.ParsedInfoMatcher)

      reloaded = Repo.reload!(candidate)
      assert reloaded.provider_id == "stub"
      assert reloaded.title == "Doctor Who"
      assert reloaded.confidence == 1.0
    end

    test "reports match failures without derailing the pass, and broadcasts one change event" do
      lp = library_path_fixture(%{type: "series", path: "/media/Series"})

      import_candidate_fixture(%{
        library_path_id: lp.id,
        anchor_key: "doctor who",
        relative_path: "Doctor Who (2005)/Season 01/Doctor Who - S01E01.mkv"
      })

      Phoenix.PubSub.subscribe(Mydia.PubSub, "import_candidates:#{lp.id}")

      scope = lp.id |> SelectionScope.new() |> SelectionScope.select_page(["doctor who"])

      assert {:ok, %{files: 0, failures: 1}} =
               ImportCandidates.rematch(scope, matcher: Mydia.Library.CrashingMatcher)

      assert_receive {:import_candidates_changed, lp_id}
      assert lp_id == lp.id
    end
  end

  describe "accept/2 and accept_all_matched/2" do
    setup :setup_metadata_stub

    test "accept/2 promotes a matched group and skips a no-match one" do
      lp = library_path_fixture(%{type: "movies"})

      movie =
        media_item_fixture(%{type: "movie", tmdb_id: Mydia.MetadataStubProvider.movie_tmdb_id()})

      matched =
        import_candidate_fixture(%{
          library_path_id: lp.id,
          anchor_key: "matched",
          media_type: "movie",
          provider_type: "tmdb",
          provider_id: to_string(movie.tmdb_id),
          title: movie.title,
          year: movie.year,
          confidence: 0.95,
          parsed_info: %{"type" => "movie"}
        })

      unmatched =
        import_candidate_fixture(%{
          library_path_id: lp.id,
          anchor_key: "unmatched",
          media_type: "movie",
          parsed_info: %{"type" => "movie"}
        })

      scope =
        lp.id |> SelectionScope.new() |> SelectionScope.select_page(["matched", "unmatched"])

      assert {:ok, %{accepted: 1, skipped: 1}} =
               ImportCandidates.accept(scope, config: Mydia.Metadata.default_relay_config())

      refute Repo.get(ImportCandidate, matched.id)
      assert Repo.get(ImportCandidate, unmatched.id)
      assert Repo.exists?(from(f in MediaFile, where: f.media_item_id == ^movie.id))
    end

    test "accept_all_matched/2 imports every matched group and excludes no-match groups" do
      lp = library_path_fixture(%{type: "movies"})

      movie =
        media_item_fixture(%{type: "movie", tmdb_id: Mydia.MetadataStubProvider.movie_tmdb_id()})

      import_candidate_fixture(%{
        library_path_id: lp.id,
        anchor_key: "matched",
        media_type: "movie",
        provider_type: "tmdb",
        provider_id: to_string(movie.tmdb_id),
        title: movie.title,
        year: movie.year,
        confidence: 0.95,
        parsed_info: %{"type" => "movie"}
      })

      import_candidate_fixture(%{
        library_path_id: lp.id,
        anchor_key: "unmatched",
        media_type: "movie",
        parsed_info: %{"type" => "movie"}
      })

      assert {:ok, %{accepted: 1, skipped: 1}} =
               ImportCandidates.accept_all_matched(lp.id,
                 config: Mydia.Metadata.default_relay_config()
               )

      assert {[group], nil} = ImportCandidates.page(lp.id)
      assert group.anchor_key == "unmatched"
    end

    test "accept and import-all both reject a group with conflicting providers" do
      lp = library_path_fixture(%{type: "movies"})
      first_movie = media_item_fixture(%{type: "movie", tmdb_id: 61_001})
      second_movie = media_item_fixture(%{type: "movie", tmdb_id: 61_002})

      first =
        import_candidate_fixture(%{
          library_path_id: lp.id,
          anchor_key: "conflict",
          relative_path: "Conflict/a.mkv",
          media_type: "movie",
          provider_type: "tmdb",
          provider_id: to_string(first_movie.tmdb_id),
          confidence: 1.0,
          parsed_info: %{"type" => "movie"}
        })

      second =
        import_candidate_fixture(%{
          library_path_id: lp.id,
          anchor_key: "conflict",
          relative_path: "Conflict/b.mkv",
          media_type: "movie",
          provider_type: "tmdb",
          provider_id: to_string(second_movie.tmdb_id),
          confidence: 1.0,
          parsed_info: %{"type" => "movie"}
        })

      scope = lp.id |> SelectionScope.new() |> SelectionScope.select_page(["conflict"])

      assert {:ok, %{accepted: 0, skipped: 1}} = ImportCandidates.accept(scope)
      assert {:ok, %{accepted: 0, skipped: 1}} = ImportCandidates.accept_all_matched(lp.id)

      assert Repo.get(ImportCandidate, first.id)
      assert Repo.get(ImportCandidate, second.id)
      refute Repo.exists?(MediaFile)
    end

    test "accept keyset-pages selected groups instead of materializing the full selection" do
      lp = library_path_fixture(%{type: "movies"})
      movie = media_item_fixture(%{type: "movie", tmdb_id: 61_003})

      for n <- 1..5 do
        import_candidate_fixture(%{
          library_path_id: lp.id,
          anchor_key: "movie-#{n}",
          relative_path: "Movie #{n}/movie.mkv",
          media_type: "movie",
          provider_type: "tmdb",
          provider_id: to_string(movie.tmdb_id),
          title: movie.title,
          year: movie.year,
          confidence: 1.0,
          parsed_info: %{"type" => "movie"}
        })
      end

      parent = self()
      scope = lp.id |> SelectionScope.new() |> SelectionScope.select_all_matching(%{})

      assert {:ok, %{accepted: 5, skipped: 0}} =
               ImportCandidates.accept(scope,
                 group_page_size: 2,
                 after_group_page: fn groups -> send(parent, {:group_page, length(groups)}) end
               )

      assert_receive {:group_page, 2}
      assert_receive {:group_page, 2}
      assert_receive {:group_page, 1}
      refute_receive {:group_page, _}
      assert Repo.aggregate(MediaFile, :count) == 5
    end
  end
end
