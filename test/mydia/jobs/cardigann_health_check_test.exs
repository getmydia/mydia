defmodule Mydia.Jobs.CardigannHealthCheckTest do
  # Changes the global Logger level and probes through Bypass.
  use Mydia.DataCase, async: false

  import ExUnit.CaptureLog
  import Mydia.IndexersFixtures

  alias Mydia.Indexers.RateLimiter
  alias Mydia.Jobs.CardigannHealthCheck

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

  describe "perform/1 logging" do
    setup do
      original_level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: original_level) end)
      :ok
    end

    test "a rate-limited probe is logged at info, not as an unhealthy indexer" do
      bypass = Bypass.open()
      Bypass.stub(bypass, "GET", "/", fn conn -> Plug.Conn.resp(conn, 200, "<html/>") end)

      Bypass.stub(bypass, "GET", "/search", fn conn ->
        Plug.Conn.resp(conn, 429, "Too Many Requests")
      end)

      linked_definition("http://localhost:#{bypass.port}")

      log = capture_log([level: :info], fn -> assert :ok = perform_sweep() end)

      assert log =~
               "[info] [CardigannHealthCheckJob] Rate-limited by tracker: Tracker answered HTTP 429; paused until "

      refute log =~ "Indexer unhealthy"
    end

    test "a failed probe still warns" do
      bypass = Bypass.open()
      Bypass.stub(bypass, "GET", "/", fn conn -> Plug.Conn.resp(conn, 200, "<html/>") end)
      Bypass.stub(bypass, "GET", "/search", fn conn -> Plug.Conn.resp(conn, 500, "boom") end)

      linked_definition("http://localhost:#{bypass.port}")

      log = capture_log([level: :info], fn -> assert :ok = perform_sweep() end)

      assert log =~ "[warning] [CardigannHealthCheckJob] Indexer unhealthy"
      refute log =~ "Rate-limited by tracker"
    end
  end

  defp perform_sweep, do: CardigannHealthCheck.perform(%Oban.Job{args: %{}})

  # The probe reads the links in the stored definition YAML, not the column.
  defp linked_definition(url) do
    definition = cardigann_definition_fixture(%{enabled: true})
    on_exit(fn -> RateLimiter.clear_indexer(definition.id) end)

    yaml =
      String.replace(definition.definition, ~r/^links:\n(?:  - .*\n?)+/m, "links:\n  - #{url}\n")

    {:ok, definition} =
      definition
      |> Ecto.Changeset.change(%{definition: yaml})
      |> Repo.update()

    definition
  end
end
