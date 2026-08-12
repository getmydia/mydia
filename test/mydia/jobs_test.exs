defmodule Mydia.JobsTest do
  use Mydia.DataCase

  alias Mydia.Jobs

  # Oban is disabled in the test environment (config/test.exs sets
  # plugins: false, engine: false, queues: false, deliberately, to keep its
  # pool off the SQL Sandbox), so the real, running production crontab can
  # never be read from a test. These tests therefore cover cron_args_from/2,
  # the pure lookup every caller goes through, against explicit crontab
  # fixtures instead.
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

  # build_job/2's tests above cover the args-threading logic, but nothing yet
  # exercises trigger_job/1 itself: the line the original bug lived on
  # (`worker.new(%{}) |> Oban.insert()`) and the only remaining untested
  # composition. This crontab is a fixture invented for this test, not a copy
  # of config/config.exs's real schedule: production crontab coverage is
  # impossible here because config/test.exs deliberately disables Oban's
  # plugins to keep its pool off the SQL Sandbox, so nothing can read the real
  # crontab from a test. Every entry uses "0 0 1 1 *" (midnight
  # on January 1st) so it cannot fire and insert a stray job row during a
  # test run.
  describe "trigger_job/1" do
    setup do
      engine = if Mydia.DB.postgres?(), do: Oban.Engines.Basic, else: Oban.Engines.Lite

      start_supervised!(
        {Oban,
         repo: Mydia.Repo,
         engine: engine,
         queues: [],
         plugins: [
           {Oban.Plugins.Cron,
            crontab: [
              {"0 0 1 1 *", Mydia.Jobs.BlacklistCleanup,
               args: %{"fixture" => "trigger_job_test"}},
              {"0 0 1 1 *", Mydia.Jobs.EventCleanup}
            ]}
         ]}
      )

      :ok
    end

    test "enqueues a job whose args equal the fixture crontab's declared args" do
      assert {:ok, job} = Jobs.trigger_job(Mydia.Jobs.BlacklistCleanup)

      assert job.args == %{"fixture" => "trigger_job_test"}
    end

    test "enqueues a job with an empty args map for a worker with no declared args" do
      assert {:ok, job} = Jobs.trigger_job(Mydia.Jobs.EventCleanup)

      assert job.args == %{}
    end
  end
end
