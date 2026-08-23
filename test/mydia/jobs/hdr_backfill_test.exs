defmodule Mydia.Jobs.HdrBackfillTest do
  # Tests mutate Application env (ffprobe_path) and drive an isolated Oban
  # instance, so we run them serially.
  use Mydia.DataCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  import ExUnit.CaptureLog
  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Jobs.HdrBackfill
  alias Mydia.Library.MediaFile

  # A Dolby Vision profile 5 stream: no display-compatible base layer
  # (Hdr.from_ffprobe/1 maps dv_profile 5 to base: nil regardless of
  # bl_compat_id), so this exercises the one fact the migration could never
  # recover from stored data. needs_frame_probe?/1 is false whenever
  # dv_profile is set, so this never triggers the second, frame-level probe
  # and a single-response shim is enough.
  @dv_profile_5_json ~s({"streams":[{"codec_type":"video","codec_name":"hevc","side_data_list":[{"side_data_type":"DOVI configuration record","dv_profile":5,"dv_bl_signal_compatibility_id":0}]}],"format":{"duration":"60.0","format_name":"matroska"}})

  # perform/1 reschedules itself with a singular Oban.insert/1 whenever it
  # processes at least one row (see the module doc). The app skips Oban in
  # test (engine: false), so that insert cannot resolve without a locally
  # started instance; mirrors the setup in metadata_backfill_test.exs.
  setup do
    engine = if Mydia.DB.postgres?(), do: Oban.Engines.Basic, else: Oban.Engines.Lite
    start_supervised!({Oban, repo: Mydia.Repo, engine: engine, testing: :manual})

    on_exit(fn -> Application.delete_env(:mydia, :ffprobe_path) end)

    :ok
  end

  describe "selection" do
    test "selects rows with a non-null hdr_format" do
      target = media_file_fixture(%{hdr_format: :hdr10, analyzed_at: DateTime.utc_now()})
      _sdr = media_file_fixture(%{hdr_format: nil, analyzed_at: DateTime.utc_now()})

      assert HdrBackfill.pending_ids(10) == [target.id]
    end

    test "stops selecting a row once it has been stamped" do
      done = media_file_fixture(%{hdr_format: :hdr10, analyzed_at: DateTime.utc_now()})

      # hdr_backfilled_at is bookkeeping the backfill job alone writes: it is
      # deliberately absent from MediaFile's cast lists (see Task 5), so a
      # fixture cannot set it through attrs. update_all is the only way to
      # simulate an already-stamped row here, matching how the job itself
      # writes this column.
      stamp_backfilled(done)

      assert HdrBackfill.pending_ids(10) == []
    end
  end

  describe "perform/1" do
    test "stamps and skips a row whose file no longer exists, without failing" do
      # library_path_fixture's default path is a fresh tmp dir that is never
      # created on disk, so the default relative_path resolves to a file
      # that does not exist without any extra setup.
      file = media_file_fixture(%{hdr_format: :hdr10, analyzed_at: DateTime.utc_now()})

      assert :ok = perform_job(HdrBackfill, %{})
      assert Repo.get(MediaFile, file.id).hdr_backfilled_at != nil
      assert HdrBackfill.pending_ids(10) == []
    end

    test "writes HDR columns on an already-analyzed row" do
      # REGRESSION: routing this through Library.apply_analysis/2 was a
      # silent no-op, because that function refuses to write once
      # analyzed_at is set, which it is for every row this job targets.
      {file, shim} =
        seed_probe_target(@dv_profile_5_json, hdr_format: :hdr10, analyzed_at: DateTime.utc_now())

      try do
        assert :ok = perform_job(HdrBackfill, %{})

        reloaded = Repo.get(MediaFile, file.id)
        assert reloaded.dolby_vision_profile == 5
        assert reloaded.hdr_backfilled_at != nil
      after
        File.rm(shim)
      end
    end

    test "leaves codec, resolution and analysis_attempts untouched" do
      {file, shim} =
        seed_probe_target(@dv_profile_5_json,
          hdr_format: :hdr10,
          codec: "hevc",
          resolution: "2160p",
          analyzed_at: DateTime.utc_now()
        )

      try do
        assert :ok = perform_job(HdrBackfill, %{})

        reloaded = Repo.get(MediaFile, file.id)
        assert reloaded.codec == "hevc"
        assert reloaded.resolution == "2160p"
        assert reloaded.analysis_attempts == file.analysis_attempts
      after
        File.rm(shim)
      end
    end

    test "stamps and skips a row when ffprobe fails, without failing" do
      # Structurally identical to the missing-file branch above, but a
      # separate failure path in backfill_one/1 (the {:error, reason} case
      # rather than the is_nil(path) or not File.exists?(path) case): a
      # broken/unreadable file must not spin forever either.
      dir =
        Path.join(System.tmp_dir!(), "hdr_backfill_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      relative = "video.mkv"
      File.write!(Path.join(dir, relative), "fake video content")
      library_path = library_path_fixture(%{type: "movies", path: dir})

      file =
        media_file_fixture(%{
          hdr_format: :hdr10,
          analyzed_at: DateTime.utc_now(),
          library_path_id: library_path.id,
          relative_path: relative
        })

      shim = write_fail_shim()
      Application.put_env(:mydia, :ffprobe_path, shim)

      try do
        assert :ok = perform_job(HdrBackfill, %{})

        reloaded = Repo.get(MediaFile, file.id)
        assert reloaded.hdr_backfilled_at != nil
        assert is_nil(reloaded.dolby_vision_profile)
        assert HdrBackfill.pending_ids(10) == []
      after
        File.rm(shim)
      end
    end
  end

  describe "perform/1 self-reschedule via the real Oban dispatch path" do
    # REGRESSION: every test above drives the worker through
    # Oban.Testing.perform_job/2, which builds an in-memory job and calls the
    # executor directly. It never inserts or claims a real oban_jobs row, so
    # the self-reschedule's `Oban.insert/1` call inside perform/1 never has a
    # conflicting row to collide with, and would appear to pass even if the
    # `unique:` config made it silently insert nothing.
    #
    # Both Oban engines this app can use (Basic for PostgreSQL, Lite for
    # SQLite) move a claimed job's row to "executing" BEFORE calling
    # perform/1, and it stays "executing" for the whole call. That is the
    # exact condition the bug needs to reproduce: this test has to make a
    # real row sit in "executing" state while perform/1, running because of
    # that very claim, tries to insert a follow-up job for itself.
    #
    # Oban.drain_queue/2 is the tool for that: unlike perform_job/2, it goes
    # through conf.engine.fetch_jobs/3 for real (see
    # deps/oban/lib/oban/engines/lite.ex's fetch_jobs/3: a genuine
    # `UPDATE ... SET state = 'executing'`), then calls the executor, so the
    # row this job's own self-insert has to avoid colliding with is a real
    # database row, not a fixture.
    test "drains every pending row across more than one batch, not just the first" do
      # A small batch size against 5 pending rows forces multiple passes:
      # batch 1 (2 rows), batch 2 (2 rows), batch 3 (1 row, reschedules once
      # more to observe the set is empty), batch 4 (0 rows, stops).
      Application.put_env(:mydia, :hdr_backfill_batch_size, 2)
      on_exit(fn -> Application.delete_env(:mydia, :hdr_backfill_batch_size) end)

      # No library_path is attached, so absolute_path resolves to nothing and
      # every row takes the "missing file" branch in backfill_one/1 -- no
      # ffprobe shim needed, and irrelevant to what this test is proving.
      files =
        for _ <- 1..5 do
          media_file_fixture(%{hdr_format: :hdr10, analyzed_at: DateTime.utc_now()})
        end

      assert {:ok, _job} = Oban.insert(HdrBackfill.new(%{}))

      # with_scheduled: true stages the 5-second-delayed follow-up jobs
      # immediately rather than waiting; with_recursion: true keeps draining
      # newly-staged jobs until a pass processes nothing further, which is
      # exactly the loop perform/1's self-reschedule drives in production.
      result = Oban.drain_queue(queue: :analysis, with_scheduled: true, with_recursion: true)

      # Under the bug, only the first batch (2 rows) would ever run: the
      # self-reschedule's Oban.insert/1 would match this job's own
      # still-executing row and silently insert nothing, so drain_queue would
      # report exactly one successful job and stop.
      assert result.success > 1,
             "expected more than one HdrBackfill job to run, got #{inspect(result)}"

      for file <- files do
        assert Repo.get(MediaFile, file.id).hdr_backfilled_at != nil
      end

      assert HdrBackfill.pending_ids(10) == []

      # A second, independent confirmation that real follow-up jobs were
      # inserted and executed: more than one HdrBackfill row actually
      # completed in oban_jobs, not just the one this test inserted by hand.
      completed_backfill_jobs =
        Oban.Job
        |> where(worker: "Mydia.Jobs.HdrBackfill")
        |> where(state: "completed")
        |> Repo.aggregate(:count)

      assert completed_backfill_jobs > 1
    end
  end

  describe "enqueue_once/0" do
    test "does not raise when no Oban instance is registered" do
      # This module's top-level setup starts a supervised Oban instance so
      # every other test's internal Oban.insert/1 call resolves. Stop it
      # here, right before calling enqueue_once/0, so
      # Oban.Registry.config(Oban) genuinely raises RuntimeError -- the same
      # failure application.ex's boot call is exposed to (an Oban instance
      # not registered under the expected name, or not started yet) -- not
      # a vacuous pass through an instance that happens to still be running.
      stop_supervised!(Oban)

      log =
        capture_log(fn ->
          assert :ok = HdrBackfill.enqueue_once()
        end)

      assert log =~ "failed to enqueue"
    end
  end

  describe "completeness against every legacy hdr_format shape" do
    # Guards against the migration's provisional-mapping decision silently
    # regressing: the "Dolby Vision" -> 'hdr10' mapping in
    # priv/repo/migrations/20260823032730_canonicalize_hdr_format.exs exists
    # only so that pending_ids/1's `hdr_format IS NOT NULL` predicate stays
    # complete. Nothing caught a change to that mapping before this job
    # existed, because the predicate it feeds did not exist either.
    #
    # This reruns the real migration (not a hand-copied description of it)
    # against the sandboxed Mydia.Repo, so a mutation to the migration file
    # is what changes this test's outcome, not the test file. It first rolls
    # the schema back to just before the migration ran (dropping the three
    # HDR columns it already added for real, on the persistent test
    # database, before ExUnit even starts), then re-runs up/0. This mirrors
    # backfill_import_groups_test.exs's "up/0 and down/0 via the real
    # migrator" pattern, including its Postgres caveat below.
    #
    # Ecto.Migrator against a DataCase-sandboxed repo deadlocks under
    # PostgreSQL (see backfill_import_groups_test.exs for the full writeup),
    # so this only needs to run once, on SQLite, the default `mix test`
    # adapter.
    @describetag skip:
                   Mydia.DB.postgres?() and
                     "Ecto.Migrator against the DataCase-sandboxed Repo deadlocks on Postgres (see backfill_import_groups_test.exs)"

    # The migration's real, already-applied version. Unlike a synthetic
    # version, down/4 only runs a migration's down/0 for a version it finds
    # recorded in schema_migrations, and this is the one actually recorded.
    @migration_version 20_260_823_032_730

    unless Code.ensure_loaded?(Mydia.Repo.Migrations.CanonicalizeHdrFormat) do
      Code.require_file("priv/repo/migrations/20260823032730_canonicalize_hdr_format.exs")
    end

    test "pending_ids/1 selects every non-SDR legacy shape, and never the SDR one" do
      rows = %{
        dolby_vision: media_file_fixture(%{analyzed_at: DateTime.utc_now()}),
        hdr10: media_file_fixture(%{analyzed_at: DateTime.utc_now()}),
        hdr: media_file_fixture(%{analyzed_at: DateTime.utc_now()}),
        hdr10_plus: media_file_fixture(%{analyzed_at: DateTime.utc_now()}),
        hlg: media_file_fixture(%{analyzed_at: DateTime.utc_now()}),
        sdr: media_file_fixture(%{analyzed_at: DateTime.utc_now()}),
        unrecognized: media_file_fixture(%{analyzed_at: DateTime.utc_now()})
      }

      assert :ok = run_migration_down()

      # Seed every legacy display string the migration is documented to
      # handle, via raw SQL: the hdr_format column exists but the three HDR
      # columns the compiled MediaFile schema also expects do not, at this
      # exact moment, so nothing routed through the MediaFile changeset
      # could touch this table right now.
      set_legacy_hdr_format(rows.dolby_vision, "Dolby Vision")
      set_legacy_hdr_format(rows.hdr10, "HDR10")
      set_legacy_hdr_format(rows.hdr, "HDR")
      set_legacy_hdr_format(rows.hdr10_plus, "HDR10+")
      set_legacy_hdr_format(rows.hlg, "HLG")
      set_legacy_hdr_format(rows.unrecognized, "Some Unknown Format")
      # rows.sdr already carries hdr_format: nil, the fixture default.

      # Re-run the migration for real: the exact code path a fresh install
      # upgrading through this migration goes through.
      assert :ok = run_migration_up()

      pending = MapSet.new(HdrBackfill.pending_ids(10))

      non_sdr_ids =
        MapSet.new([
          rows.dolby_vision.id,
          rows.hdr10.id,
          rows.hdr.id,
          rows.hdr10_plus.id,
          rows.hlg.id
        ])

      assert MapSet.subset?(non_sdr_ids, pending)
      refute rows.sdr.id in pending
      refute rows.unrecognized.id in pending

      # Direct value assertions on the mapping itself. Everything above only
      # asserts set membership in pending_ids/1: a mutation that swapped, say,
      # the HDR10+ and HLG branches in the migration would still select both
      # rows for backfill and pass every assertion above unchanged, because
      # both would still land on a non-nil canonical atom. Only reading back
      # the actual hdr_format value catches that, and this migration
      # irreversibly rewrites the column on every row of every existing
      # install, so it is worth pinning down exactly.
      assert hdr_format_of(rows.dolby_vision) == :hdr10
      assert hdr_format_of(rows.hdr10) == :hdr10
      assert hdr_format_of(rows.hdr) == :hdr10
      assert hdr_format_of(rows.hdr10_plus) == :hdr10_plus
      assert hdr_format_of(rows.hlg) == :hlg
      assert hdr_format_of(rows.unrecognized) == nil
    end

    defp hdr_format_of(%MediaFile{id: id}), do: Repo.get!(MediaFile, id).hdr_format

    defp run_migration_up do
      Ecto.Migrator.up(
        Repo,
        @migration_version,
        Mydia.Repo.Migrations.CanonicalizeHdrFormat,
        log: false
      )
    end

    defp run_migration_down do
      Ecto.Migrator.down(
        Repo,
        @migration_version,
        Mydia.Repo.Migrations.CanonicalizeHdrFormat,
        log: false
      )
    end

    defp set_legacy_hdr_format(%MediaFile{id: id}, value) do
      Repo.query!("UPDATE media_files SET hdr_format = '#{value}' WHERE id = '#{id}'")
    end
  end

  # Builds a media file whose absolute_path resolves to a real file on disk,
  # points the ffprobe shim at `json`, and returns {media_file, shim_path}.
  # Mirrors seed_real_files/2 and write_ok_shim/1 in file_analysis_test.exs,
  # and write_json_shim/1 in file_analyzer_test.exs: the stub seam is
  # `:ffprobe_path` pointing at a shell script that prints fixed JSON, not a
  # binary media fixture (none exists for Dolby Vision, and a real sample is
  # far too large to commit).
  defp seed_probe_target(json, attrs) do
    dir = Path.join(System.tmp_dir!(), "hdr_backfill_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    relative = "video.mkv"
    File.write!(Path.join(dir, relative), "fake video content")

    library_path = library_path_fixture(%{type: "movies", path: dir})

    file =
      media_file_fixture(
        Map.merge(
          %{library_path_id: library_path.id, relative_path: relative},
          Map.new(attrs)
        )
      )

    shim = write_json_shim(json)
    Application.put_env(:mydia, :ffprobe_path, shim)

    {file, shim}
  end

  defp write_json_shim(json) do
    escaped = String.replace(json, "'", "'\\''")
    path = Path.join(System.tmp_dir!(), "hdr_backfill_shim_#{:rand.uniform(10_000_000)}.sh")
    File.write!(path, "#!/bin/sh\nprintf '%s' '#{escaped}'\n")
    File.chmod!(path, 0o755)
    path
  end

  # Mirrors write_fail_shim/0 in file_analysis_test.exs: exits non-zero so
  # FileAnalyzer.analyze/1 returns {:error, :ffprobe_failed}.
  defp write_fail_shim do
    path = Path.join(System.tmp_dir!(), "hdr_backfill_fail_shim_#{:rand.uniform(10_000_000)}.sh")
    File.write!(path, "#!/bin/sh\necho 'simulated failure' >&2\nexit 1\n")
    File.chmod!(path, 0o755)
    path
  end

  defp stamp_backfilled(%MediaFile{} = media_file) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {1, _} =
      from(f in MediaFile, where: f.id == ^media_file.id)
      |> Repo.update_all(set: [hdr_backfilled_at: now])

    media_file
  end
end
