defmodule Mydia.Downloads.BuiltIn.SupervisorTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.BuiltIn.{Config, Engine, Status, Vpn}
  alias Mydia.Downloads.BuiltIn.Supervisor, as: BuiltInSupervisor

  defp ids(children), do: Enum.map(children, &Supervisor.child_spec(&1, []).id)

  defp engine_spec(children) do
    Enum.find(children, &(Supervisor.child_spec(&1, []).id == Engine))
    |> Supervisor.child_spec([])
  end

  defp engine_opts(children) do
    {Engine, :start_link, [opts]} = engine_spec(children).start
    opts
  end

  describe "summarize_clients/1" do
    test "keeps enabled torrent handlers and flags a taken name, enabled or not" do
      clients = [
        %{name: "SAB", type: :sabnzbd, enabled: true},
        %{name: "qb", type: :qbittorrent, enabled: false},
        %{name: " built-IN ", type: :sabnzbd, enabled: false}
      ]

      assert {[], true} = BuiltInSupervisor.summarize_clients(clients)

      assert {[:transmission], false} =
               BuiltInSupervisor.summarize_clients([
                 %{name: "T", type: :transmission, enabled: true}
               ])
    end
  end

  test "disabled starts nothing" do
    assert BuiltInSupervisor.children(%Config{enabled?: false}, credentials: {"u", "p"}) == []
  end

  test "without a VPN the engine autostarts" do
    children = BuiltInSupervisor.children(%Config{enabled?: true}, credentials: {"u", "p"})
    assert ids(children) == [Status, Engine]
    assert engine_opts(children)[:autostart] == true
  end

  test "with a VPN the gate starts it" do
    children =
      BuiltInSupervisor.children(%Config{enabled?: true, vpn?: true}, credentials: {"u", "p"})

    assert ids(children) == [Status, Engine, Vpn]
    assert engine_opts(children)[:autostart] == false
  end

  test "the engine's API port comes from the config" do
    children =
      BuiltInSupervisor.children(%Config{enabled?: true, api_port: 4036}, credentials: {"u", "p"})

    assert engine_opts(children)[:api_port] == 4036
  end

  test "the engine gets time to stop rqbit before it is killed" do
    children = BuiltInSupervisor.children(%Config{enabled?: true}, credentials: {"u", "p"})
    assert engine_spec(children).shutdown == 15_000
  end
end
