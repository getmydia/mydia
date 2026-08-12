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

  # trigger_job/1 is the exact pipe that carried the original bug (enqueueing
  # every worker with %{}, discarding whatever args its crontab entry
  # declared) and Oban.insert/1 cannot run without a live Oban. build_job/2 is
  # everything trigger_job/1 does except the insert, so asserting on the
  # changeset it returns is the regression guard for the real fix: if
  # trigger_job/1 ever regresses to building the job from raw %{} again,
  # these tests catch it directly, unlike perform_job(MediaServerWatchedSync,
  # %{}), which would still pass since that worker's catch-all maps an empty
  # map to the same "all_enabled" its crontab entry already declares.
  describe "build_job/2" do
    test "a worker whose crontab entry declares args produces a changeset with those args" do
      crontab = [
        {"*/30 * * * *", Mydia.Jobs.MediaServerWatchedSync, args: %{"mode" => "all_enabled"}}
      ]

      changeset = Jobs.build_job(crontab, Mydia.Jobs.MediaServerWatchedSync)

      assert Ecto.Changeset.get_field(changeset, :args) == %{"mode" => "all_enabled"}
    end

    test "a worker with a two-tuple entry and no args produces an empty args map" do
      crontab = [{"0 5 * * *", Mydia.Jobs.TrashCleanup}]

      changeset = Jobs.build_job(crontab, Mydia.Jobs.TrashCleanup)

      assert Ecto.Changeset.get_field(changeset, :args) == %{}
    end

    test "a worker absent from the crontab produces an empty args map" do
      crontab = [{"0 5 * * *", Mydia.Jobs.TrashCleanup}]

      changeset = Jobs.build_job(crontab, Mydia.Jobs.MediaServerWatchedSync)

      assert Ecto.Changeset.get_field(changeset, :args) == %{}
    end

    test "the changeset's worker is the module asked for" do
      changeset = Jobs.build_job([], Mydia.Jobs.TrashCleanup)

      assert Ecto.Changeset.get_field(changeset, :worker) == inspect(Mydia.Jobs.TrashCleanup)
    end
  end
end
