defmodule Mydia.Jobs.LibraryScanSchedulerTest do
  # async: false: the runtime-config test below mutates the global
  # :mydia, :runtime_config application env (same reason
  # test/mydia/settings_test.exs's "runtime library paths" describe block
  # is async: false).
  use Mydia.DataCase, async: false

  import Mydia.Factory

  alias Mydia.Jobs.LibraryScanner
  alias Mydia.Jobs.LibraryScanScheduler

  @now ~U[2026-07-30 12:00:00Z]

  # Records which library paths the scheduler decided to scan.
  defp recording_enqueuer(test_pid) do
    fn library_path ->
      send(test_pid, {:enqueued, library_path.id})
      :ok
    end
  end

  defp tick!(now \\ @now) do
    LibraryScanScheduler.tick(now, recording_enqueuer(self()))
  end

  defp scanned_ids do
    Enum.sort(collect_scanned([]))
  end

  defp collect_scanned(acc) do
    receive do
      {:enqueued, id} -> collect_scanned([id | acc])
    after
      0 -> acc
    end
  end

  describe "due selection" do
    test "a path with no interval is never scanned" do
      insert(:library_path, scan_interval: nil, last_scan_at: nil)

      tick!()

      assert scanned_ids() == []
    end

    test "an unmonitored path is never scanned" do
      insert(:library_path, scan_interval: 900, monitored: false, last_scan_at: nil)

      tick!()

      assert scanned_ids() == []
    end

    test "a disabled path is never scanned" do
      insert(:library_path, scan_interval: 900, disabled: true, last_scan_at: nil)

      tick!()

      assert scanned_ids() == []
    end

    test "a path that has never been scanned is due" do
      path = insert(:library_path, scan_interval: 3600, last_scan_at: nil)

      tick!()

      assert scanned_ids() == [path.id]
    end

    test "a path whose interval has not elapsed is skipped" do
      insert(:library_path,
        scan_interval: 3600,
        last_scan_at: DateTime.add(@now, -1800, :second)
      )

      tick!()

      assert scanned_ids() == []
    end

    test "a path whose interval has exactly elapsed is due" do
      path =
        insert(:library_path,
          scan_interval: 3600,
          last_scan_at: DateTime.add(@now, -3600, :second)
        )

      tick!()

      assert scanned_ids() == [path.id]
    end

    test "each due path is enqueued independently" do
      a = insert(:library_path, scan_interval: 900, last_scan_at: nil)
      b = insert(:library_path, scan_interval: 900, last_scan_at: nil)

      tick!()

      assert scanned_ids() == Enum.sort([a.id, b.id])
    end
  end

  describe "enqueued job shape" do
    test "the job built for a due path carries library_path_id but not skip_delay" do
      library_path = insert(:library_path, scan_interval: 900, last_scan_at: nil)

      changeset = LibraryScanner.new(%{library_path_id: library_path.id})

      assert changeset.changes.args[:library_path_id] == library_path.id
      refute Map.has_key?(changeset.changes.args, :skip_delay)
    end
  end

  describe "due_paths/1 and runtime-config paths" do
    test "does not return a library path that only exists in runtime config" do
      runtime_config = %Mydia.Config.Schema{
        # Config.Schema.get_runtime_library_paths/0 also checks the legacy
        # `media.movies_path`/`media.tv_path` fields; both keys must be present
        # (even if nil) or dot access on a nil/incomplete :media raises.
        media: %{movies_path: nil, tv_path: nil},
        library_paths: [
          %{
            path: "/media/runtime-only",
            type: :movies,
            monitored: true,
            scan_interval: 900
          }
        ]
      }

      original_runtime = Application.get_env(:mydia, :runtime_config)
      Application.put_env(:mydia, :runtime_config, runtime_config)

      on_exit(fn ->
        if original_runtime do
          Application.put_env(:mydia, :runtime_config, original_runtime)
        else
          Application.delete_env(:mydia, :runtime_config)
        end
      end)

      # Sanity check: Settings.list_library_paths/1 merges this path in with a
      # synthesized runtime:: id and last_scan_at: nil, so it looks perpetually
      # due. This is exactly the trap due_paths/1 must avoid.
      assert Enum.any?(
               Mydia.Settings.list_library_paths(),
               &(&1.path == "/media/runtime-only")
             )

      due_paths = LibraryScanScheduler.due_paths(@now)

      refute Enum.any?(due_paths, &(&1.path == "/media/runtime-only"))
    end
  end
end
