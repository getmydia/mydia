defmodule MetadataRelay.ClientConfigEnvTest do
  # Writes the :client_config_relays application env, which is global, so this
  # module cannot run alongside others.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Conn, only: [get_resp_header: 2]

  alias MetadataRelay.ClientConfig

  @cae1_1 "https://cae1-1.relay.mydia.dev"
  @cae1_2 "https://cae1-2.relay.mydia.dev"

  setup do
    previous = Application.fetch_env(:metadata_relay, :client_config_relays)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:metadata_relay, :client_config_relays, value)
        :error -> Application.delete_env(:metadata_relay, :client_config_relays)
      end
    end)
  end

  defp configure(value), do: Application.put_env(:metadata_relay, :client_config_relays, value)

  describe "relay_urls/0" do
    test "serves the built-in list when unset" do
      configure(nil)
      assert ClientConfig.relay_urls() == ClientConfig.default_relay_urls()
    end

    test "serves the configured list" do
      configure("#{@cae1_1},#{@cae1_2}")
      assert ClientConfig.relay_urls() == [@cae1_1, @cae1_2]
    end

    test "serves the built-in list when the value is rejected" do
      configure("http://relay.example.test")
      assert ClientConfig.relay_urls() == ClientConfig.default_relay_urls()
    end
  end

  describe "log_config/0" do
    test "says why a configured value was ignored" do
      configure("http://relay.example.test")

      log = capture_log(fn -> assert ClientConfig.log_config() == :ok end)

      assert log =~ "CLIENT_CONFIG_RELAYS ignored"
      assert log =~ "http://relay.example.test"
    end
  end

  describe "GET /client-config" do
    test "returns the configured list as JSON" do
      configure("#{@cae1_1},#{@cae1_2}")

      conn = MetadataRelay.Router.call(Plug.Test.conn(:get, "/client-config"), [])

      assert conn.status == 200
      assert ["application/json" <> _] = get_resp_header(conn, "content-type")
      assert %{"p2p" => %{"relays" => [@cae1_1, @cae1_2]}} = Jason.decode!(conn.resp_body)
    end

    test "returns the built-in list when unset" do
      configure(nil)

      conn = MetadataRelay.Router.call(Plug.Test.conn(:get, "/client-config"), [])

      assert %{"p2p" => %{"relays" => relays}} = Jason.decode!(conn.resp_body)
      assert relays == ClientConfig.default_relay_urls()
    end
  end
end
