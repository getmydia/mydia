defmodule Mydia.JobsTest do
  use Mydia.DataCase
  use Oban.Testing, repo: Mydia.Repo

  alias Mydia.Jobs

  setup do
    # The app skips starting Oban in test (testing: :manual in config/test.exs),
    # so Oban.config/0 has no running instance to read. Start an isolated one
    # with a crontab mirroring the two config.exs entries these tests exercise,
    # so cron_args/1 and trigger_job/1 hit the real Oban.Plugins.Cron lookup
    # path instead of a stub. Keep this in sync with config/config.exs if
    # either entry's schedule or args changes.
    #
    # `testing: :manual` cannot be used here: Oban.Config.new/1 unconditionally
    # forces `plugins: []` whenever `testing` is `:manual` or `:inline`, which
    # would erase the crontab before cron_args/1 ever saw it. Leaving `testing`
    # at its `:disabled` default keeps the crontab plugin's config intact.
    # `queues: []` keeps this instance from actually dispatching any job it
    # inserts, and the DataCase sandbox defaults to shared mode, so the Cron
    # plugin's own process can use the same sandboxed connection safely.
    engine = if Mydia.DB.postgres?(), do: Oban.Engines.Basic, else: Oban.Engines.Lite

    start_supervised!(
      {Oban,
       repo: Mydia.Repo,
       engine: engine,
       queues: [],
       plugins: [
         {Oban.Plugins.Cron,
          crontab: [
            {"*/30 * * * *", Mydia.Jobs.MediaServerWatchedSync, args: %{"mode" => "all_enabled"}},
            {"0 5 * * *", Mydia.Jobs.TrashCleanup}
          ]}
       ]}
    )

    :ok
  end

  describe "cron_args/1" do
    test "returns the crontab args for a worker that declares them" do
      assert Jobs.cron_args(Mydia.Jobs.MediaServerWatchedSync) == %{"mode" => "all_enabled"}
    end

    test "returns an empty map for a scheduled worker with no args" do
      assert Jobs.cron_args(Mydia.Jobs.TrashCleanup) == %{}
    end

    test "returns an empty map for a worker that is not scheduled" do
      assert Jobs.cron_args(Mydia.Jobs.NotScheduledAnywhere) == %{}
    end
  end

  describe "trigger_job/1" do
    test "enqueues every cron worker with exactly its crontab args" do
      for %{worker: worker} <- Jobs.list_cron_jobs() do
        assert {:ok, job} = Jobs.trigger_job(worker)

        assert job.args == Jobs.cron_args(worker),
               "#{inspect(worker)} was enqueued with #{inspect(job.args)}"
      end
    end
  end
end
