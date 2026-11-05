defmodule Mydia.Downloads.BuiltIn.StatusTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.BuiltIn.Status

  setup do
    name = :"status_#{System.unique_integer([:positive])}"
    start_supervised!({Status, name: name})
    Phoenix.PubSub.subscribe(Mydia.PubSub, Status.topic())
    %{name: name}
  end

  test "starts with the engine starting and the VPN off", %{name: name} do
    assert %Status{engine: :starting, vpn: :off, port: nil, warnings: []} = Status.get(name)
  end

  test "carries config warnings from start" do
    name = :"status_w_#{System.unique_integer([:positive])}"
    start_supervised!({Status, name: name, warnings: [{:invalid_port, "x"}]}, id: name)
    assert %Status{warnings: [{:invalid_port, "x"}]} = Status.get(name)
  end

  test "put/3 stores and broadcasts", %{name: name} do
    :ok = Status.put(name, :vpn, {:down, :missing_net_admin})
    assert %Status{vpn: {:down, :missing_net_admin}} = Status.get(name)
    assert_receive {:built_in_status, %Status{vpn: {:down, :missing_net_admin}}}
  end

  describe "blocking_reason/1" do
    test "nil when the engine is running" do
      assert Status.blocking_reason(%Status{engine: :running}) == nil
    end

    test "the VPN reason wins over the engine's when the VPN is down" do
      status = %Status{engine: {:stopped, :vpn_down}, vpn: {:down, :missing_tun}}
      assert Status.blocking_reason(status) == :missing_tun
    end

    test "the engine reason otherwise" do
      assert Status.blocking_reason(%Status{engine: {:crashed, {:engine_exit, 1}, 5}}) ==
               {:engine_exit, 1}

      assert Status.blocking_reason(%Status{engine: :starting}) == :engine_starting
    end
  end

  describe "describe/1" do
    test "every reason has fix text" do
      reasons = [
        :missing_net_admin,
        :missing_tun,
        :split_group_missing,
        {:reserved_variable, "DNS_ADDRESS"},
        {:invalid_port, "x"},
        {:vpn_auth_failed, "bad credentials"},
        :vpn_down,
        {:vpn_down, "last log line"},
        :vpn_unreachable,
        :leak_detected,
        {:leak_check_failed, "timeout"},
        {:port_forward_failed, "no port"},
        {:engine_exit, 101},
        :engine_starting,
        :rqbit_not_found,
        {:spawn_failed, "eacces"}
      ]

      for reason <- reasons do
        message = Status.describe(reason)
        assert message != "", inspect(reason)
        refute message =~ "—"
      end

      assert Status.describe(:missing_net_admin) =~ "cap_add"
      assert Status.describe(:missing_tun) =~ "/dev/net/tun"
      assert Status.describe(:split_group_missing) =~ "PGID"
      assert Status.describe({:reserved_variable, "DNS_ADDRESS"}) =~ "MYDIA_VPN_DNS_ADDRESS"
    end
  end
end
