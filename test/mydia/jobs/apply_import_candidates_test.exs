defmodule Mydia.Jobs.ApplyImportCandidatesTest do
  # Promotion runs through Mydia.MetadataStubProvider, a process-global
  # registration -- see Mydia.MetadataStub's moduledoc for why every test that
  # relies on it must run synchronously.
  use Mydia.DataCase, async: false

  import Mydia.MediaFixtures
  import Mydia.MetadataStub
  import Mydia.SettingsFixtures

  alias Mydia.ImportCandidates
  alias Mydia.Jobs.ApplyImportCandidates
  alias Mydia.Library.ImportCandidate
  alias Mydia.Repo

  setup :setup_metadata_stub

  defp queue(candidate) do
    candidate
    |> Ecto.Changeset.change(%{
      queued_op: "accept",
      queued_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.update!()
  end

  describe "drain_accepted/2" do
    test "promotes a queued group and removes its candidates" do
      lp = library_path_fixture(%{type: "series"})

      # The provider_id must be the stub's actual catalog series: the ref-keyed
      # catalog only resolves {:tvdb, series_tvdb_id()}, not an arbitrary
      # made-up id (see MetadataStubProvider's moduledoc).
      candidate =
        import_candidate_fixture(%{
          library_path_id: lp.id,
          relative_path: "Wandering Aurora/s01e01.mkv",
          provider_type: "tvdb",
          provider_id: to_string(Mydia.MetadataStubProvider.series_tvdb_id()),
          title: "Wandering Aurora",
          media_type: "tv_show",
          confidence: 0.95,
          parsed_info: %{"season" => 1, "episodes" => [1]}
        })
        |> queue()

      assert {:ok, %{promoted: 1, failed: 0, remaining: 0}} =
               ImportCandidates.drain_accepted(lp.id,
                 config: Mydia.Metadata.default_relay_config(),
                 allow_episode_creation: true
               )

      refute Repo.get(ImportCandidate, candidate.id)
    end

    test "a group with no provider match clears its marker and records why" do
      lp = library_path_fixture(%{type: "series"})

      candidate =
        import_candidate_fixture(%{
          library_path_id: lp.id,
          relative_path: "Unknown Folder/file.mkv"
        })
        |> queue()

      assert {:ok, %{promoted: 0, failed: 1, remaining: 0}} =
               ImportCandidates.drain_accepted(lp.id)

      reloaded = Repo.get!(ImportCandidate, candidate.id)
      assert is_nil(reloaded.queued_op)
      assert reloaded.queue_error == "No provider match to import from."
    end

    test "a group whose files match different titles clears its marker" do
      lp = library_path_fixture(%{type: "series"})

      for {path, provider_id} <- [{"Split Anchor/a.mkv", "9001"}, {"Split Anchor/b.mkv", "9002"}] do
        import_candidate_fixture(%{
          library_path_id: lp.id,
          relative_path: path,
          provider_type: "tvdb",
          provider_id: provider_id,
          media_type: "tv_show",
          confidence: 0.9
        })
        |> queue()
      end

      assert {:ok, %{promoted: 0, failed: 1, remaining: 0}} =
               ImportCandidates.drain_accepted(lp.id)

      assert [error | _] =
               ImportCandidate
               |> Ecto.Query.where([c], c.library_path_id == ^lp.id)
               |> Repo.all()
               |> Enum.map(& &1.queue_error)

      assert error == "Files in this folder match different titles."
    end

    test "drains more groups than one anchor page holds" do
      lp = library_path_fixture(%{type: "series"})

      # All three anchors resolve through Mydia.MetadataStubProvider, whose
      # catalog has exactly one series -- see its moduledoc. Sharing that
      # series' id (rather than three distinct ones the stub cannot
      # differentiate) keeps each promotion from racing to create a second
      # media item with the same tvdb id; each anchor still stays its own
      # group, and each candidate targets a distinct episode of that series.
      series_id = to_string(Mydia.MetadataStubProvider.series_tvdb_id())

      for n <- 1..3 do
        import_candidate_fixture(%{
          library_path_id: lp.id,
          relative_path: "Show #{n}/s01e0#{n}.mkv",
          provider_type: "tvdb",
          provider_id: series_id,
          title: "Show #{n}",
          media_type: "tv_show",
          confidence: 0.95,
          parsed_info: %{"season" => 1, "episodes" => [n]}
        })
        |> queue()
      end

      assert {:ok, %{promoted: 3, remaining: 0}} =
               ImportCandidates.drain_accepted(lp.id,
                 anchor_page_size: 1,
                 config: Mydia.Metadata.default_relay_config(),
                 allow_episode_creation: true
               )
    end

    test "promotes only the queued rows of a mixed anchor" do
      lp = library_path_fixture(%{type: "series"})

      # provider_id must be the stub's actual catalog series id -- see the
      # comment on the first test in this describe block.
      queued =
        import_candidate_fixture(%{
          library_path_id: lp.id,
          relative_path: "Wandering Aurora/s01e01.mkv",
          provider_type: "tvdb",
          provider_id: to_string(Mydia.MetadataStubProvider.series_tvdb_id()),
          title: "Wandering Aurora",
          media_type: "tv_show",
          confidence: 0.95,
          parsed_info: %{"season" => 1, "episodes" => [1]}
        })
        |> queue()

      # What a scan discovering a new file mid-drain leaves behind: a pending
      # row under an anchor whose import is already under way.
      newcomer =
        import_candidate_fixture(%{
          library_path_id: lp.id,
          relative_path: "Wandering Aurora/s01e02.mkv"
        })

      assert newcomer.anchor_key == queued.anchor_key

      assert {:ok, %{promoted: 1, remaining: 0}} =
               ImportCandidates.drain_accepted(lp.id,
                 config: Mydia.Metadata.default_relay_config(),
                 allow_episode_creation: true
               )

      refute Repo.get(ImportCandidate, queued.id)
      assert Repo.get(ImportCandidate, newcomer.id)
    end

    test "an anchor queued for both accept and rematch promotes only the accept-queued row" do
      lp = library_path_fixture(%{type: "series"})

      # provider_id must be the stub's actual catalog series id -- see the
      # comment on the first test in this describe block. `rematching` below
      # deliberately keeps an arbitrary id: it is never promoted, so it never
      # reaches the stub's fetch.
      accepted =
        import_candidate_fixture(%{
          library_path_id: lp.id,
          relative_path: "Wandering Aurora/s01e01.mkv",
          provider_type: "tvdb",
          provider_id: to_string(Mydia.MetadataStubProvider.series_tvdb_id()),
          title: "Wandering Aurora",
          media_type: "tv_show",
          confidence: 0.95,
          parsed_info: %{"season" => 1, "episodes" => [1]}
        })
        |> queue()

      # A different provider_id under the same anchor. If eligibility were
      # ever computed over every queued_op at once (rather than "accept"
      # alone), this row's presence would flip provider_count to 2 and the
      # accepted row would wrongly be refused as :conflicting_providers.
      rematching =
        import_candidate_fixture(%{
          library_path_id: lp.id,
          relative_path: "Wandering Aurora/s01e02.mkv",
          provider_type: "tvdb",
          provider_id: "9002",
          title: "Wandering Aurora (uncertain)",
          media_type: "tv_show",
          confidence: 0.4
        })

      assert rematching.anchor_key == accepted.anchor_key

      rematching
      |> Ecto.Changeset.change(%{
        queued_op: "rematch",
        queued_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.update!()

      assert {:ok, %{promoted: 1, remaining: 0}} =
               ImportCandidates.drain_accepted(lp.id,
                 config: Mydia.Metadata.default_relay_config(),
                 allow_episode_creation: true
               )

      refute Repo.get(ImportCandidate, accepted.id)

      reloaded_rematching = Repo.get!(ImportCandidate, rematching.id)
      assert reloaded_rematching.queued_op == "rematch"
      assert is_nil(reloaded_rematching.queue_error)
    end

    test "an early anchor stuck in a transient failure does not strand a later, healthy anchor" do
      lp = library_path_fixture(%{type: "series"})
      series_id = to_string(Mydia.MetadataStubProvider.series_tvdb_id())

      # "blocked" sorts before "healthy", so with anchor_page_size: 1 it lands
      # on the drain's first anchor page, ahead of the healthy anchor below.
      stuck =
        import_candidate_fixture(%{
          library_path_id: lp.id,
          anchor_key: "blocked show",
          relative_path: "Blocked Show/s01e01.mkv",
          provider_type: "tvdb",
          provider_id: series_id,
          title: "Blocked Show",
          media_type: "tv_show",
          confidence: 0.95,
          parsed_info: %{"season" => 1, "episodes" => [1]}
        })
        |> queue()

      # A relay connection failure is transient: the same fetch can succeed on
      # the next attempt, so the marker stays for Oban's retry. Only the TVDB
      # series ref fails; the healthy anchor below uses the TMDB ref.
      :ok = Mydia.MetadataStubProvider.fail_fetch_by_ref(Mydia.MetadataStubProvider.series_ref())
      on_exit(fn -> Mydia.MetadataStubProvider.clear_fetch_by_ref_failure() end)

      healthy =
        import_candidate_fixture(%{
          library_path_id: lp.id,
          anchor_key: "healthy show",
          relative_path: "Healthy Show/s01e01.mkv",
          provider_type: "tmdb",
          provider_id: to_string(Mydia.MetadataStubProvider.series_tmdb_id()),
          title: "Healthy Show",
          media_type: "tv_show",
          confidence: 0.95,
          parsed_info: %{"season" => 1, "episodes" => [1]}
        })
        |> queue()

      assert {:ok, %{promoted: 1, remaining: 1}} =
               ImportCandidates.drain_accepted(lp.id,
                 anchor_page_size: 1,
                 config: Mydia.Metadata.default_relay_config(),
                 allow_episode_creation: true
               )

      refute Repo.get(ImportCandidate, healthy.id)

      reloaded_stuck = Repo.get!(ImportCandidate, stuck.id)
      assert reloaded_stuck.queued_op == "accept"
      assert is_nil(reloaded_stuck.queue_error)
    end

    test "a file already in the library at the same path clears its marker" do
      lp = library_path_fixture(%{type: "series"})

      candidate =
        import_candidate_fixture(%{
          library_path_id: lp.id,
          relative_path: "Wandering Aurora/s01e01.mkv",
          provider_type: "tvdb",
          provider_id: to_string(Mydia.MetadataStubProvider.series_tvdb_id()),
          title: "Wandering Aurora",
          media_type: "tv_show",
          confidence: 0.95,
          parsed_info: %{"season" => 1, "episodes" => [1]}
        })
        |> queue()

      media_file_fixture(%{
        library_path_id: lp.id,
        episode_id: episode_fixture().id,
        relative_path: candidate.relative_path
      })

      assert {:ok, %{promoted: 0, failed: 1, remaining: 0}} =
               ImportCandidates.drain_accepted(lp.id,
                 config: Mydia.Metadata.default_relay_config(),
                 allow_episode_creation: true
               )

      reloaded = Repo.get!(ImportCandidate, candidate.id)
      assert is_nil(reloaded.queued_op)
      assert reloaded.queue_error == "A file at this path is already in the library."
    end

    # Regression for #1212: a multi-episode file parses to two episode numbers,
    # which CandidatePromotion cannot attach to one episode. It used to sit in
    # Queued through every Oban retry and then forever.
    test "a multi-episode file clears its marker instead of staying queued" do
      lp = library_path_fixture(%{type: "series"})

      candidate =
        import_candidate_fixture(%{
          library_path_id: lp.id,
          relative_path: "Wandering Aurora/s01e01e02.mkv",
          provider_type: "tvdb",
          provider_id: to_string(Mydia.MetadataStubProvider.series_tvdb_id()),
          title: "Wandering Aurora",
          media_type: "tv_show",
          confidence: 0.95,
          parsed_info: %{"season" => 1, "episodes" => [1, 2]}
        })
        |> queue()

      assert {:ok, %{promoted: 0, failed: 1, remaining: 0}} =
               ImportCandidates.drain_accepted(lp.id,
                 config: Mydia.Metadata.default_relay_config(),
                 allow_episode_creation: true
               )

      reloaded = Repo.get!(ImportCandidate, candidate.id)
      assert is_nil(reloaded.queued_op)
      assert reloaded.queue_error =~ "Couldn't tell which episode this file is."
    end

    test "a match the provider no longer has clears its marker" do
      lp = library_path_fixture(%{type: "series"})

      candidate =
        import_candidate_fixture(%{
          library_path_id: lp.id,
          relative_path: "Vanished Show/s01e01.mkv",
          provider_type: "tvdb",
          provider_id: to_string(Mydia.MetadataStubProvider.missing_id()),
          title: "Vanished Show",
          media_type: "tv_show",
          confidence: 0.95,
          parsed_info: %{"season" => 1, "episodes" => [1]}
        })
        |> queue()

      assert {:ok, %{promoted: 0, failed: 1, remaining: 0}} =
               ImportCandidates.drain_accepted(lp.id,
                 config: Mydia.Metadata.default_relay_config(),
                 allow_episode_creation: true
               )

      reloaded = Repo.get!(ImportCandidate, candidate.id)
      assert is_nil(reloaded.queued_op)

      assert reloaded.queue_error ==
               "The matched title no longer exists at the provider. Re-match this group."
    end

    # The group's match is built from its first candidate, so a movie file
    # sharing a folder with an episode resolves to a show it can never attach
    # to. Members load ordered by path, so the episode's path sorts first.
    test "a movie file grouped with an episode clears its marker" do
      lp = library_path_fixture(%{type: "series"})
      series_id = to_string(Mydia.MetadataStubProvider.series_tvdb_id())

      candidates =
        for {path, type} <- [
              {"Wandering Aurora/s01e01.mkv", "tv_show"},
              {"Wandering Aurora/s02-feature.mkv", "movie"}
            ] do
          import_candidate_fixture(%{
            library_path_id: lp.id,
            anchor_key: "wandering aurora",
            relative_path: path,
            provider_type: "tvdb",
            provider_id: series_id,
            title: "Wandering Aurora",
            media_type: type,
            confidence: 0.95,
            parsed_info: %{"season" => 1, "episodes" => [1]}
          })
          |> queue()
        end

      assert {:ok, %{promoted: 0, failed: 1, remaining: 0}} =
               ImportCandidates.drain_accepted(lp.id,
                 config: Mydia.Metadata.default_relay_config(),
                 allow_episode_creation: true
               )

      for candidate <- candidates do
        reloaded = Repo.get!(ImportCandidate, candidate.id)
        assert is_nil(reloaded.queued_op)

        assert reloaded.queue_error ==
                 "This file's type doesn't match the matched title (movie or show)."
      end
    end

    # Regression for #1212: the file insert rejects a movie in a series-only
    # library path with a changeset error that repeats on every retry.
    test "a movie in a series library clears its marker with the validation reason" do
      lp = library_path_fixture(%{type: "series"})

      candidate =
        import_candidate_fixture(%{
          library_path_id: lp.id,
          relative_path: "Stub Feature/feature.mkv",
          provider_type: "tmdb",
          provider_id: to_string(Mydia.MetadataStubProvider.movie_tmdb_id()),
          title: "Stub Feature",
          media_type: "movie",
          confidence: 0.95
        })
        |> queue()

      assert {:ok, %{promoted: 0, failed: 1, remaining: 0}} =
               ImportCandidates.drain_accepted(lp.id,
                 config: Mydia.Metadata.default_relay_config(),
                 allow_episode_creation: true
               )

      reloaded = Repo.get!(ImportCandidate, candidate.id)
      assert is_nil(reloaded.queued_op)
      assert reloaded.queue_error =~ "This file can't be added to the library: "
      assert reloaded.queue_error =~ "cannot add movies to a library path"
      assert String.length(reloaded.queue_error) <= 200
    end

    test "on the final attempt a transient failure clears its marker with the reason" do
      lp = library_path_fixture(%{type: "series"})

      candidate =
        import_candidate_fixture(%{
          library_path_id: lp.id,
          relative_path: "Blocked Show/s01e01.mkv",
          provider_type: "tvdb",
          provider_id: to_string(Mydia.MetadataStubProvider.series_tvdb_id()),
          title: "Blocked Show",
          media_type: "tv_show",
          confidence: 0.95,
          parsed_info: %{"season" => 1, "episodes" => [1]}
        })
        |> queue()

      :ok = Mydia.MetadataStubProvider.fail_fetch_by_ref(Mydia.MetadataStubProvider.series_ref())
      on_exit(fn -> Mydia.MetadataStubProvider.clear_fetch_by_ref_failure() end)

      opts = [config: Mydia.Metadata.default_relay_config(), allow_episode_creation: true]

      assert {:ok, %{remaining: 1}} = ImportCandidates.drain_accepted(lp.id, opts)
      assert Repo.get!(ImportCandidate, candidate.id).queued_op == "accept"

      assert {:ok, %{promoted: 0, remaining: 0} = result} =
               ImportCandidates.drain_accepted(lp.id, [final_attempt: true] ++ opts)

      refute Map.has_key?(result, :reasons)

      reloaded = Repo.get!(ImportCandidate, candidate.id)
      assert is_nil(reloaded.queued_op)
      assert reloaded.queue_error =~ "Import failed after several attempts: "
      assert reloaded.queue_error =~ "stubbed fetch failure"
    end

    test "a library with nothing queued is a no-op" do
      lp = library_path_fixture(%{type: "series"})

      assert {:ok, %{promoted: 0, failed: 0, remaining: 0}} =
               ImportCandidates.drain_accepted(lp.id)
    end
  end

  describe "final-attempt give-up" do
    defp queued_series_candidate(lp, path) do
      import_candidate_fixture(%{
        library_path_id: lp.id,
        relative_path: path,
        provider_type: "tvdb",
        provider_id: to_string(Mydia.MetadataStubProvider.series_tvdb_id()),
        title: "Blocked Show",
        media_type: "tv_show",
        confidence: 0.95,
        parsed_info: %{"season" => 1, "episodes" => [1]}
      })
      |> queue()
    end

    test "clears only anchors with a recorded failure, leaving a mid-drain row queued" do
      lp = library_path_fixture(%{type: "series"})
      failed = queued_series_candidate(lp, "Blocked Show/s01e01.mkv")
      fresh = queued_series_candidate(lp, "Other Folder/s01e01.mkv")

      # `fresh` stands for a row a concurrent accept marked after the sweep
      # passed its anchor: it has no entry in the reasons the drain recorded.
      reasons = %{
        failed.anchor_key =>
          {:metadata_fetch_failed, %Mydia.Metadata.Provider.Error{message: "boom"}}
      }

      assert :ok = Mydia.ImportCandidates.AcceptQueue.give_up_queued(lp.id, reasons)

      failed = Repo.get!(ImportCandidate, failed.id)
      assert is_nil(failed.queued_op)
      assert failed.queue_error =~ "boom"

      assert Repo.get!(ImportCandidate, fresh.id).queued_op == "accept"
    end

    test "a provider error with no message still clears with the generic reason" do
      lp = library_path_fixture(%{type: "series"})
      candidate = queued_series_candidate(lp, "Blocked Show/s01e01.mkv")

      reasons = %{
        candidate.anchor_key =>
          {:metadata_fetch_failed,
           %Mydia.Metadata.Provider.Error{type: :connection_failed, message: nil}}
      }

      assert :ok = Mydia.ImportCandidates.AcceptQueue.give_up_queued(lp.id, reasons)

      reloaded = Repo.get!(ImportCandidate, candidate.id)
      assert is_nil(reloaded.queued_op)
      assert reloaded.queue_error =~ "Import failed after several attempts"
    end
  end

  describe "perform/1" do
    test "returns :ok when everything drained" do
      lp = library_path_fixture(%{type: "series"})

      assert :ok =
               ApplyImportCandidates.perform(%Oban.Job{
                 args: %{"library_path_id" => lp.id}
               })
    end

    test "reports failure for retry before the final attempt and succeeds on it" do
      lp = library_path_fixture(%{type: "series"})

      import_candidate_fixture(%{
        library_path_id: lp.id,
        relative_path: "Blocked Show/s01e01.mkv",
        provider_type: "tvdb",
        provider_id: to_string(Mydia.MetadataStubProvider.series_tvdb_id()),
        title: "Blocked Show",
        media_type: "tv_show",
        confidence: 0.95,
        parsed_info: %{"season" => 1, "episodes" => [1]}
      })
      |> queue()

      :ok = Mydia.MetadataStubProvider.fail_fetch_by_ref(Mydia.MetadataStubProvider.series_ref())
      on_exit(fn -> Mydia.MetadataStubProvider.clear_fetch_by_ref_failure() end)

      args = %{"library_path_id" => lp.id}

      assert {:error, _} =
               ApplyImportCandidates.perform(%Oban.Job{args: args, attempt: 1, max_attempts: 3})

      assert :ok =
               ApplyImportCandidates.perform(%Oban.Job{args: args, attempt: 3, max_attempts: 3})

      assert ImportCandidates.count_by_status(lp.id, "queued") == 0
    end
  end

  describe "cancel_queued/1" do
    test "returns accept-queued rows to pending and leaves other ops alone" do
      lp = library_path_fixture(%{type: "series"})
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      accepted =
        import_candidate_fixture(%{
          library_path_id: lp.id,
          anchor_key: "wandering aurora",
          relative_path: "Wandering Aurora/s01e01.mkv",
          queued_op: "accept",
          queued_at: now,
          queue_error: "stale message"
        })

      rematching =
        import_candidate_fixture(%{
          library_path_id: lp.id,
          anchor_key: "wandering aurora",
          relative_path: "Wandering Aurora/s01e02.mkv",
          queued_op: "rematch",
          queued_at: now
        })

      scope =
        lp.id
        |> Mydia.Library.SelectionScope.new("queued")
        |> Mydia.Library.SelectionScope.select_all_matching(%{})

      assert {:ok, %{returned: 1}} = ImportCandidates.cancel_queued(scope)

      reloaded = Repo.get!(ImportCandidate, accepted.id)
      assert is_nil(reloaded.queued_op)
      assert is_nil(reloaded.queued_at)
      assert is_nil(reloaded.queue_error)
      assert Repo.get!(ImportCandidate, rematching.id).queued_op == "rematch"
    end

    test "counts only the groups whose accept marker was cleared" do
      lp = library_path_fixture(%{type: "series"})
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      accepted =
        import_candidate_fixture(%{
          library_path_id: lp.id,
          anchor_key: "wandering aurora",
          relative_path: "Wandering Aurora/s01e01.mkv",
          queued_op: "accept",
          queued_at: now
        })

      deleting =
        import_candidate_fixture(%{
          library_path_id: lp.id,
          anchor_key: "midnight harbor",
          relative_path: "Midnight Harbor/s01e01.mkv",
          queued_op: "delete",
          queued_at: now
        })

      scope =
        lp.id
        |> Mydia.Library.SelectionScope.new("queued")
        |> Mydia.Library.SelectionScope.select_all_matching(%{})

      assert {:ok, %{returned: 1}} = ImportCandidates.cancel_queued(scope)

      assert is_nil(Repo.get!(ImportCandidate, accepted.id).queued_op)
      assert Repo.get!(ImportCandidate, deleting.id).queued_op == "delete"
    end
  end
end
