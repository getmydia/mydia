defmodule Mydia.Downloads.BuiltInTest do
  use ExUnit.Case, async: false

  alias Mydia.Downloads.BuiltIn
  alias Mydia.Downloads.BuiltIn.{Config, Runtime, Status}
  alias Mydia.Settings.DownloadClientConfig

  setup do
    on_exit(fn -> BuiltIn.clear_runtime() end)
    :ok
  end

  test "no client before the engine is set up" do
    assert BuiltIn.client_configs() == []
  end

  test "client_configs/0 describes the local engine" do
    BuiltIn.put_runtime(%Runtime{
      api_port: 3030,
      credentials: {"mydia", "s3cret"},
      config: %Config{download_path: "/data/downloads"}
    })

    assert [%DownloadClientConfig{} = client] = BuiltIn.client_configs()
    assert client.name == "Built-in"
    assert client.id == "runtime::download_client::Built-in"
    assert client.type == :rqbit
    assert client.host == "127.0.0.1"
    assert client.port == 3030
    assert client.username == "mydia"
    assert client.password == "s3cret"
    assert client.download_directory == "/data/downloads"
    assert client.connection_settings == %{"managed" => true}
    assert BuiltIn.managed?(%{options: client.connection_settings})
    # Unchanged from the old hard-coded value, so upgrades keep their routing.
    assert client.priority == 10
  end

  test "client_configs/0 carries the configured priority" do
    BuiltIn.put_runtime(%Runtime{
      api_port: 3030,
      credentials: {"mydia", "s3cret"},
      config: %Config{priority: 1}
    })

    assert [%DownloadClientConfig{priority: 1}] = BuiltIn.client_configs()
  end

  describe "seeding_target/0" do
    defp put_config(fields) do
      BuiltIn.put_runtime(%Runtime{
        api_port: 3030,
        credentials: {"mydia", "s3cret"},
        config: struct!(Config, fields)
      })
    end

    test "is nil with no runtime" do
      assert BuiltIn.seeding_target() == nil
    end

    test "converts minutes to seconds and is nil with no targets" do
      put_config(seed_ratio: nil, seed_time: 90)
      assert %{ratio: nil, seed_time: 5400, action: :pause} = BuiltIn.seeding_target()

      put_config(seed_ratio: nil, seed_time: nil)
      assert BuiltIn.seeding_target() == nil

      put_config(seed_ratio: 0.0, seed_time: nil, seed_goal_action: :remove)
      assert %{ratio: ratio, seed_time: nil, action: :remove} = BuiltIn.seeding_target()
      assert ratio == 0.0
    end

    test "client_configs/0 sets remove_completed only for a remove target" do
      put_config(seed_ratio: 1.0, seed_goal_action: :remove)
      assert [%{remove_completed: true}] = BuiltIn.client_configs()

      put_config(seed_ratio: 1.0, seed_goal_action: :pause)
      assert [%{remove_completed: false}] = BuiltIn.client_configs()

      put_config(seed_goal_action: :remove)
      assert [%{remove_completed: false}] = BuiltIn.client_configs()
    end
  end

  test "guard/2 passes unmanaged configs through" do
    assert BuiltIn.guard(%{options: %{}}) == :ok
  end

  test "guard/2 returns the blocking reason for a managed config" do
    name = :"status_#{System.unique_integer([:positive])}"
    start_supervised!({Status, name: name})
    Status.put(name, :vpn, {:down, :missing_net_admin})

    assert {:error, %{message: message}} = BuiltIn.guard(%{options: %{"managed" => true}}, name)
    assert message =~ "cap_add"

    Status.put(name, :vpn, {:up, %{provider: "protonvpn", public_ip: "203.0.113.9"}})
    Status.put(name, :engine, :running)
    assert BuiltIn.guard(%{options: %{"managed" => true}}, name) == :ok
  end
end
