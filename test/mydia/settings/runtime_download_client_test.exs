defmodule Mydia.Settings.RuntimeDownloadClientTest do
  @moduledoc """
  `map_to_download_client_config/1` builds a `%DownloadClientConfig{}` from the
  runtime map field by field. A field missing from that function is silently
  replaced by the struct default, with no error anywhere: the operator sets an
  environment variable, Mydia ignores it, and nothing says so. The `categories`
  map is already dropped for exactly this reason.

  This is the regression test for that class of bug.
  """
  # Not async: setup_runtime_config/1 mutates global application env.
  use Mydia.DataCase, async: false

  alias Mydia.Settings.RuntimeConfig

  defp client_config(overrides) do
    Enum.into(overrides, %{
      name: "runtime-qbit",
      type: :qbittorrent,
      enabled: true,
      host: "localhost",
      port: 8080,
      use_ssl: false,
      username: "admin",
      password: "admin",
      priority: 1
    })
  end

  defp setup_runtime_config(download_clients) do
    config = %Mydia.Config.Schema{
      server: %Mydia.Config.Schema.Server{},
      database: %Mydia.Config.Schema.Database{},
      auth: %Mydia.Config.Schema.Auth{},
      media: %Mydia.Config.Schema.Media{},
      downloads: %Mydia.Config.Schema.Downloads{},
      logging: %Mydia.Config.Schema.Logging{},
      oban: %Mydia.Config.Schema.Oban{},
      download_clients: download_clients
    }

    previous = Application.get_env(:mydia, :runtime_config)
    Application.put_env(:mydia, :runtime_config, config)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:mydia, :runtime_config)
        value -> Application.put_env(:mydia, :runtime_config, value)
      end
    end)
  end

  describe "the built-in client" do
    alias Mydia.Downloads.BuiltIn

    setup do
      on_exit(&BuiltIn.clear_runtime/0)
    end

    test "is listed after the configured runtime clients while it runs" do
      BuiltIn.put_runtime(%BuiltIn.Runtime{
        api_port: 3030,
        credentials: {"mydia", "x"},
        config: %BuiltIn.Config{download_path: "/data/downloads"}
      })

      setup_runtime_config([client_config(%{})])

      clients = RuntimeConfig.get_runtime_download_clients()
      assert Enum.map(clients, & &1.name) == ["runtime-qbit", "Built-in"]
      assert [%{type: :rqbit}] = Enum.filter(clients, &BuiltIn.managed?/1)

      assert Enum.map(Mydia.Settings.list_download_client_configs(), & &1.name) ==
               ["runtime-qbit", "Built-in"]
    end

    test "is not listed while it is off" do
      setup_runtime_config([client_config(%{})])
      assert [%{name: "runtime-qbit"}] = RuntimeConfig.get_runtime_download_clients()
    end
  end

  describe "map_to_download_client_config/1 external_torrents" do
    test "carries an explicit mode through to the struct" do
      setup_runtime_config([client_config(%{external_torrents: :ignore})])

      [client] = RuntimeConfig.get_runtime_download_clients()

      assert client.external_torrents == :ignore
    end

    test "defaults to :auto when the runtime map omits the field" do
      setup_runtime_config([client_config(%{})])

      [client] = RuntimeConfig.get_runtime_download_clients()

      assert client.external_torrents == :auto
    end
  end
end
