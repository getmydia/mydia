defmodule Mydia.Jobs.LibraryScanSchedulerTest do
  use Mydia.DataCase, async: true

  import Mydia.Factory

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
end
