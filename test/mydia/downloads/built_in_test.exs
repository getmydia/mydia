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
