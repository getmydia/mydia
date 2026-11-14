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

  defp vpn_opts(children) do
    spec = Enum.find(children, &(Supervisor.child_spec(&1, []).id == Vpn))
    {Vpn, :start_link, [opts]} = Supervisor.child_spec(spec, []).start
    opts
  end

  test "the gate gets the hash of the settings file it waits for" do
    children =
      BuiltInSupervisor.children(%Config{enabled?: true, vpn?: true},
        credentials: {"u", "p"},
        expected_hash: "abc123"
      )

    assert vpn_opts(children)[:expected_hash] == "abc123"
  end

  test "Status starts with the config's warnings" do
    children =
      BuiltInSupervisor.children(
        %Config{enabled?: true, warnings: [{:vpn_settings_write_failed, :eacces}]},
        credentials: {"u", "p"}
      )

    spec = Enum.find(children, &(Supervisor.child_spec(&1, []).id == Status))
    {Status, :start_link, [opts]} = Supervisor.child_spec(spec, []).start
    assert opts[:warnings] == [{:vpn_settings_write_failed, :eacces}]
  end

  test "start_link builds its children from :config and registers no name" do
    pid =
      start_supervised!(
        {BuiltInSupervisor, config: %Config{enabled?: false}, credentials: {"u", "p"}}
      )

    assert Supervisor.which_children(pid) == []
    refute Process.whereis(BuiltInSupervisor) == pid
  end
end
