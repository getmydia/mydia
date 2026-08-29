defmodule Mydia.Library.OrphanReenricherTest do
  @moduledoc """
  The orphan branch was wrong in two independent ways.

  It called the relay for every orphan on every scan, including the ones whose
  answer was already cached, because `MetadataMatcher` never consults
  `MatchCandidate`. And it discarded the outcome of the work it did, reporting
  every orphan it merely located on disk as "fixed".

  These tests assert relay calls by counting invocations of an injected
  re-enrich function, so "no relay call" is proven rather than assumed.
  """
  use Mydia.DataCase, async: false

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Library
  alias Mydia.Library.OrphanReenricher

  defp orphan(library_path, name) do
    orphaned_media_file_fixture(%{
      library_path_id: library_path.id,
      relative_path: "#{name}/#{name}.mkv"
    })
  end

  defp cache_match(file, attrs) do
    {:ok, _} =
      Library.upsert_match_candidate(
        Map.merge(
          %{
            media_file_id: file.id,
            rank: 0,
            provider_type: "tmdb",
            provider_id: "603",
            title: "The Matrix",
            year: 1999,
            media_type: "movie",
            confidence: 0.97
          },
          attrs
        )
      )
  end

  defp cache_failure(file, next_retry_at) do
    {:ok, _} =
      Library.upsert_match_candidate(%{
        media_file_id: file.id,
        rank: 0,
        attempts: 1,
        last_error: "no_match",
        next_retry_at: next_retry_at
      })
  end

  # Records every call so a test can assert the relay was not touched.
  defp counting_reenrich(pid) do
    fn media_file, _file_info, _config ->
      send(pid, {:reenriched, media_file.id})
      {:error, :no_matches_found}
    end
  end

  defp file_infos(files, library_path) do
    Map.new(files, fn file ->
      {Path.join(library_path.path, file.relative_path), %{path: file.relative_path, size: 1}}
    end)
  end

  describe "a library without auto-import" do
    test "skips an orphan whose match is already cached, with no relay call" do
      library_path = library_path_fixture(%{type: "movies", auto_import: false})
      file = orphan(library_path, "matrix")
      cache_match(file, %{})

      stats =
        OrphanReenricher.run(library_path, [file], file_infos([file], library_path),
          reenrich: counting_reenrich(self())
        )

      refute_receive {:reenriched, _}, 100
      assert stats.relay_matches == 0
      assert stats.fixed == 0
      assert stats.auto_linked == 0
    end

    test "re-matches an orphan with no candidate at all" do
      library_path = library_path_fixture(%{type: "movies", auto_import: false})
      file = orphan(library_path, "unknown")

      stats =
        OrphanReenricher.run(library_path, [file], file_infos([file], library_path),
          reenrich: counting_reenrich(self())
        )

      assert_receive {:reenriched, id}, 100
      assert id == file.id
      assert stats.relay_matches == 1
    end
  end

  describe "backoff on a failed candidate" do
    test "skips a failure whose retry window has not passed" do
      library_path = library_path_fixture(%{type: "movies", auto_import: false})
      file = orphan(library_path, "failed")

      cache_failure(
        file,
        DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
      )

      stats =
        OrphanReenricher.run(library_path, [file], file_infos([file], library_path),
          reenrich: counting_reenrich(self())
        )

      refute_receive {:reenriched, _}, 100
      assert stats.relay_matches == 0
    end

    test "retries a failure whose window has passed" do
      library_path = library_path_fixture(%{type: "movies", auto_import: false})
      file = orphan(library_path, "expired")

      cache_failure(
        file,
        DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
      )

      stats =
        OrphanReenricher.run(library_path, [file], file_infos([file], library_path),
          reenrich: counting_reenrich(self())
        )

      assert_receive {:reenriched, _}, 100
      assert stats.relay_matches == 1
    end

    test "retries a failure with no window recorded at all" do
      # A NULL next_retry_at means a failure recorded before the backoff
      # shipped. Treating it as "not yet due" would strand that backlog.
      library_path = library_path_fixture(%{type: "movies", auto_import: false})
      file = orphan(library_path, "nullwindow")
      cache_failure(file, nil)

      stats =
        OrphanReenricher.run(library_path, [file], file_infos([file], library_path),
          reenrich: counting_reenrich(self())
        )

      assert_receive {:reenriched, _}, 100
      assert stats.relay_matches == 1
    end
  end

  describe "a library with auto-import" do
    test "links a cached above-threshold match without touching the relay" do
      library_path = library_path_fixture(%{type: "movies", auto_import: true})
      item = media_item_fixture(%{type: "movie", tmdb_id: 603, title: "The Matrix"})
      file = orphan(library_path, "matrix")
      cache_match(file, %{confidence: 0.97})

      stats =
        OrphanReenricher.run(library_path, [file], file_infos([file], library_path),
          reenrich: counting_reenrich(self())
        )

      refute_receive {:reenriched, _}, 100
      assert stats.relay_matches == 0
      assert stats.fixed == 1
      assert stats.auto_linked == 1
      assert Library.get_media_file!(file.id).media_item_id == item.id
    end

    test "leaves a cached below-threshold match unlinked and uncounted" do
      library_path = library_path_fixture(%{type: "movies", auto_import: true})
      _item = media_item_fixture(%{type: "movie", tmdb_id: 603, title: "The Matrix"})
      file = orphan(library_path, "lowconf")
      cache_match(file, %{confidence: 0.55})

      stats =
        OrphanReenricher.run(library_path, [file], file_infos([file], library_path),
          reenrich: counting_reenrich(self())
        )

      assert stats.relay_matches == 0
      assert stats.fixed == 0
      assert stats.auto_linked == 0
      assert Library.get_media_file!(file.id).media_item_id == nil
    end

    test "an extra is never linked from cache" do
      library_path = library_path_fixture(%{type: "movies", auto_import: true})
      _item = media_item_fixture(%{type: "movie", tmdb_id: 603, title: "The Matrix"})

      file =
        orphaned_media_file_fixture(%{
          library_path_id: library_path.id,
          relative_path: "matrix/trailer.mkv",
          extra_kind: :trailer,
          extra_source: :filename
        })

      cache_match(file, %{confidence: 0.99})

      stats =
        OrphanReenricher.run(library_path, [file], file_infos([file], library_path),
          reenrich: counting_reenrich(self())
        )

      assert stats.auto_linked == 0
      assert Library.get_media_file!(file.id).media_item_id == nil
    end
  end

  describe "honest counting" do
    test "a file the re-enrich attempt failed on is not counted as fixed" do
      # The regression against the previous behavior, which returned true
      # whenever the file was found on disk regardless of outcome.
      library_path = library_path_fixture(%{type: "movies", auto_import: false})
      file = orphan(library_path, "stillbroken")

      stats =
        OrphanReenricher.run(library_path, [file], file_infos([file], library_path),
          reenrich: fn _f, _i, _c -> {:error, :no_matches_found} end
        )

      assert stats.relay_matches == 1
      assert stats.fixed == 0
    end

    test "a file the re-enrich attempt linked is counted as fixed" do
      library_path = library_path_fixture(%{type: "movies", auto_import: false})
      file = orphan(library_path, "fixed")

      stats =
        OrphanReenricher.run(library_path, [file], file_infos([file], library_path),
          reenrich: fn _f, _i, _c -> {:ok, :enriched} end
        )

      assert stats.fixed == 1
      assert stats.auto_linked == 0
    end

    test "a file the re-enrich attempt auto-linked counts in both totals" do
      library_path = library_path_fixture(%{type: "movies", auto_import: true})
      file = orphan(library_path, "autolinked")

      stats =
        OrphanReenricher.run(library_path, [file], file_infos([file], library_path),
          reenrich: fn _f, _i, _c -> {:ok, :auto_linked} end
        )

      assert stats.fixed == 1
      assert stats.auto_linked == 1
    end

    test "an orphan not present in this scan's file list is left alone" do
      library_path = library_path_fixture(%{type: "movies", auto_import: false})
      file = orphan(library_path, "missing")

      stats = OrphanReenricher.run(library_path, [file], %{}, reenrich: counting_reenrich(self()))

      refute_receive {:reenriched, _}, 100
      assert stats == %{fixed: 0, auto_linked: 0, relay_matches: 0}
    end
  end
end
