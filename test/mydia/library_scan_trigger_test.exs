defmodule Mydia.LibraryScanTriggerTest do
  use Mydia.DataCase, async: false

  use Oban.Testing, repo: Mydia.Repo

  import Mydia.Factory

  alias Mydia.Jobs.LibraryScanner
  alias Mydia.Library

  describe "manual scan triggers" do
    test "a single-path scan skips the startup delay" do
      library_path = insert(:library_path)

      {:ok, _job} = Library.trigger_library_scan(library_path.id)

      assert_enqueued(
        worker: LibraryScanner,
        args: %{"library_path_id" => library_path.id, "skip_delay" => true}
      )
    end

    test "a full scan skips the startup delay" do
      {:ok, _job} = Library.trigger_full_library_scan()

      assert_enqueued(worker: LibraryScanner, args: %{"skip_delay" => true})
    end

    test "an adult scan skips the startup delay" do
      {:ok, _job} = Library.trigger_adult_library_scan()

      assert_enqueued(
        worker: LibraryScanner,
        args: %{"library_type" => "adult", "skip_delay" => true}
      )
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

      assert unique[:period] == 900
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
