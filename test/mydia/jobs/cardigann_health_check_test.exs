defmodule Mydia.Jobs.CardigannHealthCheckTest do
  use ExUnit.Case, async: true

  describe "configuration wiring (source config/config.exs)" do
    # config/test.exs overrides Oban to `queues: false, plugins: false`, so the
    # upstream source config is read to check the schedule for real deployments.
    setup do
      source =
        Config.Reader.read!(Path.expand("../../../config/config.exs", __DIR__), env: :prod)

      %{oban: get_in(source, [:mydia, Oban]) || []}
    end

    # Minute 45 keeps the sweep off the top of the hour, where the hourly movie
    # search already sends a burst of requests to the same trackers.
    test "the health sweep runs at minute 45", %{oban: oban} do
      {Oban.Plugins.Cron, opts} =
        Enum.find(oban[:plugins], &match?({Oban.Plugins.Cron, _opts}, &1))

      schedules =
        for {schedule, Mydia.Jobs.CardigannHealthCheck} <- Keyword.fetch!(opts, :crontab),
            do: schedule

      assert schedules == ["45 * * * *"]
    end
  end
end
