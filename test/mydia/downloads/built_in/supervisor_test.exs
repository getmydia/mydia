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
    test "keeps every client type and flags a taken name, enabled or not" do
      clients = [
        %{name: "SAB", type: :sabnzbd, enabled: true},
        %{name: " built-IN ", type: :sabnzbd, enabled: false}
      ]

      assert {[:sabnzbd, :sabnzbd], true} = BuiltInSupervisor.summarize_clients(clients)

      assert {[:transmission], false} =
               BuiltInSupervisor.summarize_clients([
                 %{name: "T", type: :transmission, enabled: true}
               ])
    end

    test "a disabled client still means an existing install" do
      assert {[:qbittorrent], false} =
               BuiltInSupervisor.summarize_clients([
                 %{name: "qb", type: :qbittorrent, enabled: false}
               ])
    end

    test "no clients is a new install" do
      assert {[], false} = BuiltInSupervisor.summarize_clients([])
    end
  end

  describe "remember/1" do
    @describetag :tmp_dir

    test "an enabled client is recorded in its state directory", %{tmp_dir: dir} do
      config = %Config{enabled?: true, state_dir: Path.join(dir, "rqbit")}
      assert :ok = BuiltInSupervisor.remember(config)
      assert File.regular?(Config.marker_path(config))
    end

    test "an explicit false forgets it", %{tmp_dir: dir} do
      config = %Config{enabled?: false, explicit: false, state_dir: dir}
      File.write!(Config.marker_path(config), "")
      assert :ok = BuiltInSupervisor.remember(config)
      refute File.exists?(Config.marker_path(config))
    end

    test "a client off for any other reason keeps the record", %{tmp_dir: dir} do
      config = %Config{enabled?: false, explicit: nil, state_dir: dir}
      File.write!(Config.marker_path(config), "")
      assert :ok = BuiltInSupervisor.remember(config)
      assert File.regular?(Config.marker_path(config))
    end

    @tag :capture_log
    test "an unwritable state directory is not fatal", %{tmp_dir: dir} do
      blocker = Path.join(dir, "file")
      File.write!(blocker, "")
      assert :ok = BuiltInSupervisor.remember(%Config{enabled?: true, state_dir: blocker})
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
