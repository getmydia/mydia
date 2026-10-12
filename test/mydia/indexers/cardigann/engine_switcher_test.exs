defmodule Mydia.Indexers.Cardigann.EngineSwitcherTest do
  # Global state: the adapter registry, persistent_term, runtime config, app env.
  use Mydia.DataCase, async: false

  alias Mydia.Indexers.Adapter.Registry
  alias Mydia.Indexers.Cardigann.{EngineSwitcher, Wasm}
  alias Mydia.Indexers.Cardigann.EngineSwitcher.{Status, Transition}
  alias Mydia.Settings.ConfigSetting

  @server :engine_switcher_test
  @unset &__MODULE__.unset/1
  def unset(_), do: nil

  setup do
    runtime = Application.get_env(:mydia, :runtime_config)
    cache_dir = Application.get_env(:mydia, :cardigann_cache_dir)
    dir = Path.join(System.tmp_dir!(), "switcher-#{System.unique_integer([:positive])}")
    Application.put_env(:mydia, :cardigann_cache_dir, dir)
    Application.put_env(:mydia, :fake_wasm_engine_pid, self())
    Application.delete_env(:mydia, :fake_wasm_engine_status)
    Repo.delete_all(ConfigSetting)
    {:ok, _} = Mydia.Config.Loader.reload()

    on_exit(fn ->
      Application.put_env(:mydia, :runtime_config, runtime)
      Application.put_env(:mydia, :cardigann_cache_dir, cache_dir)
      Application.delete_env(:mydia, :fake_wasm_engine_pid)
      :persistent_term.erase({EngineSwitcher, :active})
      Mydia.Indexers.register_adapters()
      File.rm_rf(dir)
    end)

    start_supervised!({EngineSwitcher, name: @server})
    # Wait for boot to finish, then drop its :stop so later assertions on :stop
    # prove a switch stopped the engine.
    EngineSwitcher.status(@server)
    assert_receive {:fake_engine, :stop}
    Phoenix.PubSub.subscribe(Mydia.PubSub, EngineSwitcher.topic())
    {:ok, dir: dir}
  end

  defp engine_event(event),
    do:
      Phoenix.PubSub.broadcast(Mydia.PubSub, Wasm.Engine.topic(), {:cardigann_wasm_engine, event})

  defp switch(engine), do: EngineSwitcher.switch(engine, server: @server, getenv: @unset)

  test "boots on the built-in engine" do
    assert %Status{active: :builtin, desired: :builtin, transition: nil} =
             EngineSwitcher.status(@server)

    assert Registry.get_adapter!(:cardigann) == Mydia.Indexers.Adapter.Cardigann
  end

  test "switching to prowlarr keeps built-in serving until the engine is ready" do
    assert :ok = switch(:prowlarr)
    assert_receive {:fake_engine, :ensure_started}

    assert %Status{active: :builtin, desired: :prowlarr, transition: %Transition{phase: :pending}} =
             EngineSwitcher.status(@server)

    assert Registry.get_adapter!(:cardigann) == Mydia.Indexers.Adapter.Cardigann

    engine_event({:phase, :fetching})
    engine_event({:progress, 1_000, 4_000})

    assert %Status{transition: %Transition{phase: :fetching, bytes: 1_000, total: 4_000}} =
             EngineSwitcher.status(@server)

    engine_event({:phase, :compiling})

    # A :ready the engine does not confirm is stale and changes nothing.
    engine_event(:ready)
    assert %Status{active: :builtin} = EngineSwitcher.status(@server)

    Application.put_env(:mydia, :fake_wasm_engine_status, :ready)
    engine_event(:ready)

    assert %Status{active: :prowlarr, transition: nil} = EngineSwitcher.status(@server)
    assert Registry.get_adapter!(:cardigann) == Wasm.Adapter
    assert Mydia.Indexers.CardigannFeatureFlags.active_engine() == :prowlarr
    assert_received {:cardigann_engine, %Status{active: :prowlarr}}
  end

  test "an engine that stops being ready after cutover falls back until it is ready again" do
    Application.put_env(:mydia, :fake_wasm_engine_status, :ready)
    switch(:prowlarr)
    assert %Status{active: :prowlarr, transition: nil} = EngineSwitcher.status(@server)

    Application.put_env(:mydia, :fake_wasm_engine_status, :pending)
    engine_event({:phase, :compiling})

    assert %Status{
             active: :builtin,
             desired: :prowlarr,
             transition: %Transition{phase: :compiling}
           } =
             EngineSwitcher.status(@server)

    assert Registry.get_adapter!(:cardigann) == Mydia.Indexers.Adapter.Cardigann

    Application.put_env(:mydia, :fake_wasm_engine_status, :ready)
    engine_event(:ready)
    assert %Status{active: :prowlarr, transition: nil} = EngineSwitcher.status(@server)
    assert Registry.get_adapter!(:cardigann) == Wasm.Adapter
  end

  test "an engine that is already ready cuts over at once" do
    Application.put_env(:mydia, :fake_wasm_engine_status, :ready)
    assert :ok = switch(:prowlarr)
    assert %Status{active: :prowlarr, transition: nil} = EngineSwitcher.status(@server)
  end

  test "a failure leaves built-in active and records why and when" do
    switch(:prowlarr)
    due = DateTime.utc_now() |> DateTime.add(30, :second) |> DateTime.truncate(:second)
    engine_event({:unavailable, "the engine download failed: timeout", due})

    assert %Status{
             active: :builtin,
             transition: %Transition{
               phase: :failed,
               error: "the engine download failed: timeout",
               next_retry_at: ^due
             }
           } = EngineSwitcher.status(@server)

    assert :ok = EngineSwitcher.retry_now(@server)
    assert_receive {:fake_engine, :retry_now}
  end

  test "switching back to built-in re-registers it and stops the engine" do
    Application.put_env(:mydia, :fake_wasm_engine_status, :ready)
    switch(:prowlarr)
    assert :ok = switch(:builtin)

    assert_receive {:fake_engine, :stop}

    assert %Status{active: :builtin, desired: :builtin, transition: nil} =
             EngineSwitcher.status(@server)

    assert Registry.get_adapter!(:cardigann) == Mydia.Indexers.Adapter.Cardigann
  end

  test "switching back mid-transition cancels it" do
    switch(:prowlarr)
    engine_event({:phase, :compiling})
    switch(:builtin)

    assert_receive {:fake_engine, :stop}
    assert %Status{transition: nil} = EngineSwitcher.status(@server)
    # A late event from the stopped engine changes nothing.
    engine_event(:ready)
    assert %Status{active: :builtin} = EngineSwitcher.status(@server)
  end

  test "an env-locked switch is refused" do
    assert {:error, :env_locked} =
             EngineSwitcher.switch(:prowlarr, server: @server, getenv: fn _ -> "builtin" end)

    refute_received {:fake_engine, :ensure_started}
  end

  test "remove_cache deletes the cache only while built-in is active", %{dir: dir} do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "cardigann-x.wasm"), String.duplicate("a", 100))
    assert EngineSwitcher.cache_bytes() == 100
    assert {:ok, 100} = EngineSwitcher.remove_cache(@server)
    refute File.exists?(dir)

    switch(:prowlarr)
    assert {:error, :in_use} = EngineSwitcher.remove_cache(@server)
  end
end
