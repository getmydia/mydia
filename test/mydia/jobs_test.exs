defmodule Mydia.JobsTest do
  use Mydia.DataCase

  alias Mydia.Jobs

  # Oban is disabled in the test environment (config/test.exs sets
  # plugins: false, engine: false, queues: false, deliberately, to keep its
  # pool off the SQL Sandbox), so the real, running production crontab can
  # never be read from a test. cron_args/1 itself is therefore untested here;
  # these tests cover cron_args_from/2, the pure lookup mechanism it delegates
  # to, against explicit crontab fixtures instead.
  describe "cron_args_from/2" do
    test "returns the args a matching three-tuple entry declares" do
      crontab = [
        {"*/30 * * * *", Mydia.Jobs.MediaServerWatchedSync, args: %{"mode" => "all_enabled"}}
      ]

      assert Jobs.cron_args_from(crontab, Mydia.Jobs.MediaServerWatchedSync) ==
               %{"mode" => "all_enabled"}
    end

    test "returns an empty map for a matching two-tuple entry with no args" do
      crontab = [{"0 5 * * *", Mydia.Jobs.TrashCleanup}]

      assert Jobs.cron_args_from(crontab, Mydia.Jobs.TrashCleanup) == %{}
    end

    test "returns an empty map for a worker absent from the crontab" do
      crontab = [{"0 5 * * *", Mydia.Jobs.TrashCleanup}]

      assert Jobs.cron_args_from(crontab, Mydia.Jobs.NotScheduledAnywhere) == %{}
    end

    test "returns an empty map for an empty crontab" do
      assert Jobs.cron_args_from([], Mydia.Jobs.MediaServerWatchedSync) == %{}
    end
  end
end
