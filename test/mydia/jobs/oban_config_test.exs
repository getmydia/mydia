defmodule Mydia.Jobs.ObanConfigTest do
  use ExUnit.Case, async: true

  alias Mydia.Jobs.ObanConfig
  alias Mydia.Config.Schema.Oban, as: ObanSchema

  describe "apply_runtime_config/2" do
    test "overlays poll_interval as stage_interval" do
      base = [repo: Mydia.Repo, queues: [default: 5]]
      runtime = %ObanSchema{poll_interval: 2500, max_age_days: 7}

      result = ObanConfig.apply_runtime_config(base, runtime)
      assert result[:stage_interval] == 2500
    end

    test "updates max_age in Oban.Plugins.Pruner in seconds" do
      base = [
        plugins: [
          {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
          {Oban.Plugins.Cron, crontab: []}
        ]
      ]

      runtime = %ObanSchema{poll_interval: 1000, max_age_days: 14}

      result = ObanConfig.apply_runtime_config(base, runtime)
      plugins = result[:plugins]

      assert {Oban.Plugins.Pruner, opts} =
               Enum.find(plugins, fn
                 {Oban.Plugins.Pruner, _} -> true
                 _ -> false
               end)

      assert opts[:max_age] == 14 * 86_400

      # Cron plugin is preserved
      assert Enum.any?(plugins, fn
               {Oban.Plugins.Cron, _} -> true
               _ -> false
             end)
    end

    test "handles Oban.Pruner as well as Oban.Plugins.Pruner" do
      base = [plugins: [{Oban.Pruner, max_age: 3600}]]
      runtime = %ObanSchema{poll_interval: 1000, max_age_days: 3}

      result = ObanConfig.apply_runtime_config(base, runtime)
      assert [{Oban.Pruner, opts}] = result[:plugins]
      assert opts[:max_age] == 3 * 86_400
    end

    test "handles bare atom Oban.Plugins.Pruner and Oban.Pruner" do
      base = [plugins: [Oban.Plugins.Pruner, Oban.Pruner]]
      runtime = %ObanSchema{poll_interval: 1000, max_age_days: 5}

      result = ObanConfig.apply_runtime_config(base, runtime)

      assert result[:plugins] == [
               {Oban.Plugins.Pruner, [max_age: 5 * 86_400]},
               {Oban.Pruner, [max_age: 5 * 86_400]}
             ]
    end

    test "ignores nil and non-positive poll_interval" do
      base = [stage_interval: 1000]

      assert ObanConfig.apply_runtime_config(base, %ObanSchema{
               poll_interval: nil,
               max_age_days: nil
             }) == base

      assert ObanConfig.apply_runtime_config(base, %ObanSchema{
               poll_interval: 0,
               max_age_days: nil
             }) == base

      assert ObanConfig.apply_runtime_config(base, %ObanSchema{
               poll_interval: -500,
               max_age_days: nil
             }) == base
    end

    test "ignores nil and non-positive max_age_days" do
      base = [plugins: [{Oban.Plugins.Pruner, max_age: 3600}]]

      assert ObanConfig.apply_runtime_config(base, %ObanSchema{
               poll_interval: nil,
               max_age_days: nil
             }) == base

      assert ObanConfig.apply_runtime_config(base, %ObanSchema{
               poll_interval: nil,
               max_age_days: 0
             }) == base

      assert ObanConfig.apply_runtime_config(base, %ObanSchema{
               poll_interval: nil,
               max_age_days: -1
             }) == base
    end

    test "returns base config unchanged when runtime config is nil" do
      base = [repo: Mydia.Repo, stage_interval: 1000]
      assert ObanConfig.apply_runtime_config(base, nil) == base
    end
  end
end
