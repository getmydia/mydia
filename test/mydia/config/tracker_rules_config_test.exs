defmodule Mydia.Config.TrackerRulesConfigTest do
  use ExUnit.Case, async: false

  alias Mydia.Config.Loader

  @yaml_path Path.join(
               System.tmp_dir!(),
               "tracker_rules_#{System.unique_integer([:positive])}.yml"
             )

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Mydia.Repo, shared: true)
    clear_env()

    on_exit(fn ->
      File.rm(@yaml_path)
      clear_env()
      Ecto.Adapters.SQL.Sandbox.stop_owner(pid)
    end)

    :ok
  end

  defp clear_env do
    for {k, _} <- System.get_env(),
        String.starts_with?(k, "TRACKER_RULE_"),
        do: System.delete_env(k)
  end

  defp load_env, do: Loader.load(config_file: "nonexistent.yml", sources: [:env])

  test "TRACKER_RULE_<N>_* declares rules" do
    System.put_env("TRACKER_RULE_1_TRACKER", "Velvet Lantern")
    System.put_env("TRACKER_RULE_1_SEED_RATIO", "1.5")
    System.put_env("TRACKER_RULE_1_SEED_TIME", "4320")
    System.put_env("TRACKER_RULE_1_PRIVATE", "true")
    System.put_env("TRACKER_RULE_2_TRACKER", "Copper Reel")
    System.put_env("TRACKER_RULE_2_PRIVATE", "false")

    assert {:ok, config} = load_env()

    assert [
             %{tracker: "Velvet Lantern", seed_ratio: 1.5, seed_time: 4320, private: true},
             %{tracker: "Copper Reel", seed_ratio: nil, seed_time: nil, private: false}
           ] = config.tracker_rules
  end

  test "an unreadable number is a config error, not a silently dropped field" do
    System.put_env("TRACKER_RULE_1_TRACKER", "Velvet Lantern")
    System.put_env("TRACKER_RULE_1_SEED_RATIO", "one and a half")
    assert {:error, %Ecto.Changeset{}} = load_env()
  end

  test "a negative ratio or a rule without a tracker is a config error" do
    System.put_env("TRACKER_RULE_1_TRACKER", "Velvet Lantern")
    System.put_env("TRACKER_RULE_1_SEED_RATIO", "-1")
    assert {:error, %Ecto.Changeset{}} = load_env()

    clear_env()
    System.put_env("TRACKER_RULE_1_SEED_RATIO", "1")
    assert {:error, %Ecto.Changeset{}} = load_env()
  end

  test "YAML tracker_rules parse" do
    File.write!(@yaml_path, """
    tracker_rules:
      - tracker: Velvet Lantern
        seed_ratio: 1.0
        seed_time: 2880
    """)

    assert {:ok, config} = Loader.load(config_file: @yaml_path, sources: [:yaml])
    assert [%{tracker: "Velvet Lantern", seed_ratio: 1.0, seed_time: 2880}] = config.tracker_rules
  end
end
