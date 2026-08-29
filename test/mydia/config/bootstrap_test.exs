defmodule Mydia.Config.BootstrapTest do
  # async: false because these tests write Application.get_env(:mydia, :runtime_config),
  # which is process-global.
  use ExUnit.Case, async: false

  alias Mydia.Config.{Bootstrap, Loader}
  alias Mydia.Settings

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Mydia.Repo, shared: true)
    original = Application.get_env(:mydia, :runtime_config)

    on_exit(fn ->
      Application.put_env(:mydia, :runtime_config, original)
      Ecto.Adapters.SQL.Sandbox.stop_owner(pid)
    end)

    :ok
  end

  describe "supervision position" do
    test "starts after the Repo and after the migrator" do
      # This ordering IS the correctness argument for the whole module. Above
      # Ecto.Migrator it reads config_settings on a fresh install where that
      # table does not exist yet. Missing entirely, the database layer is
      # dropped on every boot, which is the defect this child exists to fix.
      children = Mydia.Application.children()

      repo = Enum.find_index(children, &(&1 == Mydia.Repo))
      migrator = Enum.find_index(children, &match?({Ecto.Migrator, _}, &1))
      bootstrap = Enum.find_index(children, &match?({Mydia.Config.Bootstrap, _}, &1))

      assert repo, "expected a Mydia.Repo child"
      assert migrator, "expected an Ecto.Migrator child"
      assert bootstrap, "expected a Mydia.Config.Bootstrap child"

      assert repo < migrator
      assert migrator < bootstrap
    end

    test "returns :ignore so no process lingers" do
      assert :ignore = Bootstrap.start_link(skip: true)
    end

    test "the child is skipped in the test environment" do
      # The merge queries config_settings from the supervisor's process, which
      # owns no sandbox connection. Without this gate the suite would not boot.
      children = Mydia.Application.children()

      assert {Mydia.Config.Bootstrap, skip: true} in children,
             "the test environment must not run the merge at boot"
    end

    test "skip: true does not perform the merge" do
      {:ok, _} =
        Settings.upsert_config_setting(%{
          key: "flaresolverr.url",
          value: "http://should-not-be-merged:8191",
          category: :flaresolverr
        })

      phase_one = Loader.load!(sources: [:yaml, :env])
      Application.put_env(:mydia, :runtime_config, phase_one)

      assert :ignore = Bootstrap.start_link(skip: true)
      assert Settings.get_runtime_config().flaresolverr.url == nil
    end
  end

  describe "run/1" do
    test "a ConfigSetting written before boot reaches the cached runtime config" do
      {:ok, _} =
        Settings.upsert_config_setting(%{
          key: "flaresolverr.enabled",
          value: "true",
          category: :flaresolverr
        })

      {:ok, _} =
        Settings.upsert_config_setting(%{
          key: "flaresolverr.url",
          value: "http://fs.test:8191",
          category: :flaresolverr
        })

      # Reproduce phase one: the load Mydia.Application.start/2 performs before
      # the supervision tree exists, with no database layer available.
      phase_one = Loader.load!(sources: [:yaml, :env])
      Application.put_env(:mydia, :runtime_config, phase_one)

      refute Settings.get_runtime_config().flaresolverr.enabled,
             "phase one must not see the database layer"

      assert {:ok, _config} = Bootstrap.run()

      assert Settings.get_runtime_config().flaresolverr.enabled
      assert Settings.get_runtime_config().flaresolverr.url == "http://fs.test:8191"
    end

    test "a failed merge leaves the phase-one config in place" do
      phase_one = Loader.load!(sources: [:yaml, :env])
      Application.put_env(:mydia, :runtime_config, phase_one)

      # An enabled FlareSolverr with no URL fails schema validation
      # (validate_flaresolverr_url/1), so the merge is rejected and reload/1
      # must not clobber the cached config.
      {:ok, _} =
        Settings.upsert_config_setting(%{
          key: "flaresolverr.enabled",
          value: "true",
          category: :flaresolverr
        })

      assert {:error, _reason} = Bootstrap.run()
      assert Settings.get_runtime_config() == phase_one
    end
  end
end
