defmodule Mydia.PlayerTest do
  # async: false - enabled?/0 reads application env, which is global.
  use ExUnit.Case, async: false

  alias Mydia.Player

  describe "parse_env!/1" do
    test "treats unset and empty as on" do
      assert Player.parse_env!(nil)
      assert Player.parse_env!("")
    end

    test "accepts the four boolean spellings" do
      assert Player.parse_env!("true")
      assert Player.parse_env!("1")
      refute Player.parse_env!("false")
      refute Player.parse_env!("0")
    end

    test "raises on anything else, naming the variable" do
      assert_raise ArgumentError, ~r/ENABLE_PLAYER/, fn -> Player.parse_env!("flase") end
      assert_raise ArgumentError, ~r/ENABLE_PLAYER/, fn -> Player.parse_env!("TRUE") end
    end
  end

  describe "enabled?/0" do
    setup do
      previous = Application.fetch_env(:mydia, :player_enabled)
      on_exit(fn -> restore(previous) end)
    end

    test "defaults to on" do
      Application.delete_env(:mydia, :player_enabled)
      assert Player.enabled?()
    end

    test "reads the boot value" do
      Application.put_env(:mydia, :player_enabled, false)
      refute Player.enabled?()
    end
  end

  describe "children/0" do
    setup do
      previous = Application.fetch_env(:mydia, :player_enabled)
      on_exit(fn -> restore(previous) end)
    end

    test "is the player supervisor when the player is on" do
      Application.put_env(:mydia, :player_enabled, true)
      assert Player.children() == [Mydia.Player.Supervisor]
    end

    test "is nothing when the player is off" do
      Application.put_env(:mydia, :player_enabled, false)
      assert Player.children() == []
    end
  end

  describe "prune_oban_config/2" do
    @oban [
      queues: [default: 5, segments: 1, media: 3],
      plugins: [
        {Oban.Plugins.Pruner, max_age: 60},
        {Oban.Plugins.Cron,
         crontab: [
           {"* * * * *", Mydia.Jobs.FileAnalysis},
           {"*/5 * * * *", Mydia.Jobs.SegmentDetectionScheduler},
           {"0 * * * *", Mydia.Jobs.MovieSearch, args: %{"mode" => "all_monitored"}}
         ]}
      ]
    ]

    defp cron_workers(config) do
      {Oban.Plugins.Cron, cron} = List.keyfind(config[:plugins], Oban.Plugins.Cron, 0)
      Enum.map(cron[:crontab], &elem(&1, 1))
    end

    test "leaves the config alone when the player is on" do
      assert Player.prune_oban_config(@oban, true) == @oban
    end

    test "drops the segments queue and the detection scheduler when the player is off" do
      pruned = Player.prune_oban_config(@oban, false)

      assert pruned[:queues] == [default: 5, media: 3]
      assert cron_workers(pruned) == [Mydia.Jobs.FileAnalysis, Mydia.Jobs.MovieSearch]

      assert List.keyfind(pruned[:plugins], Oban.Plugins.Pruner, 0) ==
               {Oban.Plugins.Pruner, max_age: 60}
    end

    test "copes with the test environment's disabled queues and plugins" do
      config = [testing: :manual, engine: false, queues: false, plugins: false]
      assert Player.prune_oban_config(config, false) == config
    end

    test "matches the scheduler the real crontab names" do
      # config/test.exs replaces the plugins, so read what config.exs ships.
      real = "config/config.exs" |> Config.Reader.read!(env: :prod) |> get_in([:mydia, Oban])

      assert Mydia.Jobs.SegmentDetectionScheduler in cron_workers(real)

      refute Mydia.Jobs.SegmentDetectionScheduler in cron_workers(
               Player.prune_oban_config(real, false)
             )
    end
  end

  defp restore({:ok, value}), do: Application.put_env(:mydia, :player_enabled, value)
  defp restore(:error), do: Application.delete_env(:mydia, :player_enabled)
end
