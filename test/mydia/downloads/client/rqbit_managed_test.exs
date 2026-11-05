defmodule Mydia.Downloads.Client.RqbitManagedTest do
  # Starts the globally named Status server, so it cannot run async.
  use ExUnit.Case, async: false

  alias Mydia.Downloads.BuiltIn.Status
  alias Mydia.Downloads.Client.Rqbit

  describe "managed built-in config" do
    test "returns the built-in status reason instead of calling rqbit" do
      start_supervised!({Status, name: Status})
      Status.put(:engine, {:stopped, :vpn_down})

      config = %{
        type: :rqbit,
        host: "127.0.0.1",
        port: 1,
        options: %{"managed" => true},
        connection_settings: %{"managed" => true}
      }

      assert {:error, %{message: message}} = Rqbit.test_connection(config)
      assert message =~ "VPN tunnel is down"
    end
  end
end
