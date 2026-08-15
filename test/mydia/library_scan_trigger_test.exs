defmodule Mydia.LibraryScanTriggerTest do
  use Mydia.DataCase, async: false

  use Oban.Testing, repo: Mydia.Repo

  import Mydia.Factory

  alias Mydia.Jobs.LibraryScanner
  alias Mydia.Library

  describe "manual scan triggers" do
    # Oban only sets :scheduled_at (and with it the "scheduled" state) when a job
    # is inserted with :schedule_in / :scheduled_at, so the state is what
    # distinguishes an immediate insert from a delayed one.
    test "a single-path scan runs immediately" do
      library_path = insert(:library_path)

      {:ok, job} = Library.trigger_library_scan(library_path.id)

      assert_enqueued(
        worker: LibraryScanner,
        args: %{"library_path_id" => library_path.id}
      )

      assert job.state == "available"
    end

    test "a full scan runs immediately and carries no args" do
      {:ok, job} = Library.trigger_full_library_scan()

      assert_enqueued(worker: LibraryScanner, args: %{})
      assert job.args == %{}
      assert job.state == "available"
    end

    test "a full scan can be delayed by automatic callers" do
      {:ok, job} = Library.trigger_full_library_scan(schedule_in: 600)

      assert job.state == "scheduled"
      assert DateTime.compare(job.scheduled_at, DateTime.utc_now()) == :gt
    end
  end

  describe "jitter_seconds/0" do
    test "stays inside the 0 to 30 minute window" do
      for _ <- 1..200 do
        seconds = LibraryScanner.jitter_seconds()

        assert seconds >= 1
        assert seconds <= 1800
      end
    end
  end

  describe "scan job uniqueness" do
    # Runtime dedupe cannot be asserted here: config/test.exs:66-72 sets
    # `engine: false`, which disables the Oban engine that enforces `unique:`.
    # Inserting twice in a test would therefore produce two rows regardless of
    # configuration, so a behavioral assertion would be vacuous or misleading.
    # Assert the configuration itself instead, which is what actually differs.
    test "dedupes on both library_path_id and library_type" do
      unique = LibraryScanner.__opts__()[:unique]

      # :infinity, not a fixed window. Oban measures the window from
      # inserted_at, so any finite period shorter than a scan's own runtime lets
      # the next scheduler tick insert a duplicate while the first is still
      # incomplete. Combined with :states below, :infinity means exactly "one
      # incomplete scan per key at a time" and stops matching once it finishes.
      assert unique[:period] == :infinity
      assert Enum.sort(unique[:keys]) == [:library_path_id, :library_type]

      # Must cover Oban's full :incomplete state group (available, scheduled,
      # executing, retryable, suspended). A narrower list such as just
      # [:available, :scheduled, :executing] triggers a compile-time warning
      # from Oban.Worker's @after_compile check ("missing incomplete states
      # ... which may break uniqueness") and fails this project's
      # `mix compile --warnings-as-errors` gate. It would also be a real bug:
      # a scan job that failed and is waiting to retry (:retryable) would no
      # longer block a duplicate insert from the next scheduled tick.
      assert Enum.sort(unique[:states]) ==
               Enum.sort(Oban.Job.unique_states(:incomplete))
    end
  end
end
