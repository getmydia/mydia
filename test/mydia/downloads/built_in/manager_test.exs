defmodule Mydia.Downloads.BuiltIn.ManagerTest do
  # Not async: the trees it starts register Status, Engine and Vpn under their
  # module names, and the runtime entry is a global persistent_term.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Mydia.Config.Schema.BuiltInTorrent
  alias Mydia.Downloads.BuiltIn
  alias Mydia.Downloads.BuiltIn.{Config, Manager, Status, Vpn, VpnSettings}

  @fake Path.expand("../../../support/fixtures/fake_rqbit.sh", __DIR__)

  describe "summarize_clients/1" do
    test "keeps every client type and flags a taken name, enabled or not" do
      clients = [
        %{name: "SAB", type: :sabnzbd, enabled: true},
        %{name: " built-IN ", type: :sabnzbd, enabled: false}
      ]

      assert {[:sabnzbd, :sabnzbd], true} = Manager.summarize_clients(clients)

      assert {[:transmission], false} =
               Manager.summarize_clients([%{name: "T", type: :transmission, enabled: true}])
    end

    test "a disabled client still means an existing install" do
      assert {[:qbittorrent], false} =
               Manager.summarize_clients([%{name: "qb", type: :qbittorrent, enabled: false}])
    end

    test "no clients is a new install" do
      assert {[], false} = Manager.summarize_clients([])
    end
  end

  describe "remember/1" do
    @describetag :tmp_dir

    test "an enabled client is recorded in its state directory", %{tmp_dir: dir} do
      config = %Config{enabled?: true, state_dir: Path.join(dir, "rqbit")}
      assert :ok = Manager.remember(config)
      assert File.regular?(Config.marker_path(config))
    end

    test "an explicit false forgets it", %{tmp_dir: dir} do
      config = %Config{enabled?: false, explicit: false, state_dir: dir}
      File.write!(Config.marker_path(config), "")
      assert :ok = Manager.remember(config)
      refute File.exists?(Config.marker_path(config))
    end

    test "a client off for any other reason keeps the record", %{tmp_dir: dir} do
      config = %Config{enabled?: false, explicit: nil, state_dir: dir}
      File.write!(Config.marker_path(config), "")
      assert :ok = Manager.remember(config)
      assert File.regular?(Config.marker_path(config))
    end

    @tag :capture_log
    test "an unwritable state directory is not fatal", %{tmp_dir: dir} do
      blocker = Path.join(dir, "file")
      File.write!(blocker, "")
      assert :ok = Manager.remember(%Config{enabled?: true, state_dir: blocker})
    end
  end

  describe "applying config" do
    @describetag :tmp_dir
    @describetag :capture_log

    setup %{tmp_dir: dir} do
      instances = :"instances_#{System.unique_integer([:positive])}"
      start_supervised!({DynamicSupervisor, name: instances, strategy: :one_for_one})

      section = %BuiltInTorrent{
        enabled: true,
        download_path: Path.join(dir, "downloads"),
        state_path: Path.join(dir, "rqbit"),
        listen_port: 6881,
        api_port: 39_031
      }

      {:ok, store} = Agent.start_link(fn -> section end)
      on_exit(&BuiltIn.clear_runtime/0)

      %{instances: instances, store: store, gluetun_dir: Path.join(dir, "gluetun")}
    end

    defp start_manager(ctx, extra \\ []) do
      name = :"manager_#{System.unique_integer([:positive])}"

      opts =
        Keyword.merge(
          [
            name: name,
            instances: ctx.instances,
            runtime_fun: fn -> Agent.get(ctx.store, & &1) end,
            env_fun: fn -> %{} end,
            clients_fun: fn -> {[], false} end,
            rqbit_path: @fake,
            gluetun_dir: ctx.gluetun_dir
          ],
          extra
        )

      start_supervised!({Manager, opts})
      # init applies in handle_continue; a call returns after it.
      Manager.await_applied(name)
      name
    end

    defp set(ctx, changes), do: Agent.update(ctx.store, &struct!(&1, changes))

    defp instance_pids(ctx) do
      for {_, pid, _, _} <- DynamicSupervisor.which_children(ctx.instances), do: pid
    end

    defp reload(manager) do
      send(manager, {:runtime_config_reloaded, :ignored})
      # Messages from one sender arrive in order, so the reload is handled first.
      Manager.await_applied(manager)
    end

    defp settings_file(ctx), do: Path.join([ctx.gluetun_dir, "settings", "settings.env"])

    test "starts the tree and publishes the runtime entry", ctx do
      manager = start_manager(ctx)

      assert [_pid] = instance_pids(ctx)
      assert %Config{enabled?: true, port: 6881} = Manager.await_applied(manager)
      assert %BuiltIn.Runtime{api_port: 39_031} = BuiltIn.runtime()
      assert Process.whereis(Mydia.Downloads.BuiltIn.Engine)
      assert Process.whereis(Status)
    end

    test "a reload with an unchanged section leaves the instance alone", ctx do
      manager = start_manager(ctx)
      [pid] = instance_pids(ctx)
      runtime = BuiltIn.runtime()

      reload(manager)

      assert [^pid] = instance_pids(ctx)
      assert BuiltIn.runtime() == runtime
    end

    test "a VPN field edited while the VPN is off leaves the instance alone", ctx do
      manager = start_manager(ctx)
      [pid] = instance_pids(ctx)
      runtime = BuiltIn.runtime()

      set(ctx, vpn_provider: "protonvpn", vpn_server_countries: "Atlantis")
      reload(manager)

      assert [^pid] = instance_pids(ctx)
      assert BuiltIn.runtime() == runtime
      assert File.read!(settings_file(ctx)) == "VPN_ENABLED=false\n"
    end

    test "a new listen port replaces the instance and the runtime entry", ctx do
      manager = start_manager(ctx)
      [pid] = instance_pids(ctx)
      runtime = BuiltIn.runtime()

      set(ctx, listen_port: 6999)
      reload(manager)

      assert [new_pid] = instance_pids(ctx)
      refute new_pid == pid
      refute Process.alive?(pid)
      assert %BuiltIn.Runtime{config: %Config{port: 6999}} = new_runtime = BuiltIn.runtime()
      refute new_runtime.credentials == runtime.credentials
      assert %Config{port: 6999} = Manager.await_applied(manager)
    end

    test "disabling the client stops the instance and clears the runtime", ctx do
      manager = start_manager(ctx)
      [pid] = instance_pids(ctx)

      set(ctx, enabled: false)
      reload(manager)

      assert instance_pids(ctx) == []
      refute Process.alive?(pid)
      assert BuiltIn.runtime() == nil
      assert File.read!(settings_file(ctx)) == "VPN_ENABLED=false\n"
    end

    test "apply_now/1 re-reads the section", ctx do
      manager = start_manager(ctx)
      set(ctx, listen_port: 7001)
      assert :ok = Manager.apply_now(manager)
      assert %Config{port: 7001} = Manager.await_applied(manager)
    end

    test "with the VPN on, Vpn waits for the hash of the file it wrote", ctx do
      set(ctx, vpn_enabled: true, vpn_provider: "mullvad", vpn_type: "wireguard")
      manager = start_manager(ctx)

      content = File.read!(settings_file(ctx))
      assert content =~ "VPN_ENABLED=true\n"
      assert content =~ "VPN_SERVICE_PROVIDER=mullvad\n"
      assert %Config{vpn?: true} = Manager.await_applied(manager)
      assert :sys.get_state(Vpn).expected_hash == VpnSettings.hash(content)
    end

    test "turning the VPN on replaces the tree with a gated one", ctx do
      manager = start_manager(ctx)
      [pid] = instance_pids(ctx)
      refute Process.whereis(Vpn)

      set(ctx, vpn_enabled: true, vpn_provider: "mullvad")
      reload(manager)

      assert [new_pid] = instance_pids(ctx)
      refute new_pid == pid
      content = File.read!(settings_file(ctx))
      assert :sys.get_state(Vpn).expected_hash == VpnSettings.hash(content)
    end

    test "changing a VPN field replaces the tree with the new settings hash", ctx do
      set(ctx, vpn_enabled: true, vpn_provider: "mullvad", vpn_type: "wireguard")
      manager = start_manager(ctx)

      old_content = File.read!(settings_file(ctx))
      old_hash = :sys.get_state(Vpn).expected_hash
      assert old_hash == VpnSettings.hash(old_content)
      [old_pid] = instance_pids(ctx)

      set(ctx, vpn_provider: "protonvpn")
      reload(manager)

      assert [new_pid] = instance_pids(ctx)
      refute new_pid == old_pid
      new_content = File.read!(settings_file(ctx))
      assert new_content =~ "VPN_SERVICE_PROVIDER=protonvpn\n"
      new_hash = :sys.get_state(Vpn).expected_hash
      assert new_hash == VpnSettings.hash(new_content)
      refute new_hash == old_hash
    end

    test "a failed settings write is a Status warning, and Vpn stays gated", ctx do
      blocker = Path.join(ctx.tmp_dir, "blocker")
      File.write!(blocker, "")
      set(ctx, vpn_enabled: true, vpn_provider: "mullvad")
      manager = start_manager(ctx, gluetun_dir: blocker)

      config = Manager.await_applied(manager)
      assert {:vpn_settings_write_failed, :enotdir} in Status.get().warnings
      expected = VpnSettings.hash(VpnSettings.render(config, %{}))
      assert :sys.get_state(Vpn).expected_hash == expected
    end

    test "current/1 keeps the evaluated config while the client is off", ctx do
      # Wanted, but off because another client holds the reserved name.
      manager = start_manager(ctx, clients_fun: fn -> {[:sabnzbd], true} end)

      assert %Config{enabled?: false, warnings: warnings} = Manager.current(manager)
      assert {:reserved_name_taken} in warnings
      assert instance_pids(ctx) == []
    end

    test "current/1 answers without the GenServer while it is busy", ctx do
      manager = start_manager(ctx)
      :ok = :sys.suspend(manager)

      task = Task.async(fn -> Manager.current(manager) end)
      assert %Config{enabled?: true} = Task.await(task, 500)

      :ok = :sys.resume(manager)
    end

    test "current/1 is nil before any evaluation and after a raising build", ctx do
      assert Manager.current(:never_started_manager) == nil

      capture_log(fn ->
        manager = start_manager(ctx, runtime_fun: fn -> raise "boom" end)
        assert Manager.current(manager) == nil
      end)
    end

    test "a raising runtime_fun leaves the manager up with no instance", ctx do
      log =
        capture_log(fn ->
          manager = start_manager(ctx, runtime_fun: fn -> raise "boom" end)
          assert Manager.await_applied(manager) == nil
          assert Process.alive?(Process.whereis(manager))
        end)

      assert log =~ "boom"
      assert instance_pids(ctx) == []
      assert BuiltIn.runtime() == nil
    end
  end
end
