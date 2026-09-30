defmodule Mydia.Plugins.HostInstancesTest do
  # async: false: starts pools under the app-wide PoolRegistry.
  use ExUnit.Case, async: false

  alias Mydia.Plugins.Error
  alias Mydia.Plugins.Host
  alias Mydia.Plugins.HostFunctions
  alias Mydia.Plugins.SingleFlight

  @v15 Path.expand("../../support/fixtures/plugins/host_v15_fixture.wasm", __DIR__)

  defp start!(slug) do
    {:ok, _} = Host.start_plugin(slug, File.read!(@v15), imports: HostFunctions.imports_for(slug))
    on_exit(fn -> Host.stop_plugin(slug) end)
  end

  test "the import builder receives the invocation's instance id" do
    parent = self()

    builder = fn ctx ->
      send(parent, {:ctx, ctx})
      HostFunctions.imports_for("hi-ctx").(ctx)
    end

    {:ok, _} = Host.start_plugin("hi-ctx", File.read!(@v15), imports: builder)
    on_exit(fn -> Host.stop_plugin("hi-ctx") end)

    assert {:ok, _} = Host.call("hi-ctx", "handle", %{"event" => "config"}, instance_id: "inst-7")

    assert_received {:ctx,
                     %{slug: "hi-ctx", instance_id: "inst-7", invocation_id: _, test_run: false}}
  end

  test "an invocation without an instance carries a nil instance id" do
    parent = self()

    builder = fn ctx ->
      send(parent, {:ctx, ctx})
      HostFunctions.imports_for("hi-nil").(ctx)
    end

    {:ok, _} = Host.start_plugin("hi-nil", File.read!(@v15), imports: builder)
    on_exit(fn -> Host.stop_plugin("hi-nil") end)

    assert {:ok, _} = Host.call("hi-nil", "handle", %{"event" => "config"})
    assert_received {:ctx, %{instance_id: nil}}
  end

  test "the lock is per instance: one busy instance does not block another" do
    start!("hi-lock")

    :ok = SingleFlight.acquire({"hi-lock", "a"}, :skip)
    on_exit(fn -> SingleFlight.release({"hi-lock", "a"}) end)

    assert {:error, %Error{type: :busy}} =
             Host.call("hi-lock", "check-health", %{},
               handler: :check_health,
               instance_id: "a",
               single_flight: :skip
             )

    assert {:ok, %{status: :degraded}} =
             Host.call("hi-lock", "check-health", %{},
               handler: :check_health,
               instance_id: "b",
               single_flight: :skip
             )
  end

  test "setup gets its own default timeout" do
    assert Mydia.Config.Schema.defaults().plugins.setup_timeout_ms == 30_000
  end
end
