defmodule Mydia.Plugins.HostTest do
  # async: false — pools register under the app-wide Mydia.Plugins.PoolRegistry.
  use ExUnit.Case, async: false

  alias Mydia.Plugins.Error
  alias Mydia.Plugins.Host

  # A prebuilt wasm32-wasip2 component (the canonical mydia:plugin@1.0.0
  # contract). One component, many behaviors keyed by the event type — see
  # test/support/fixtures/plugins/host_test_fixture/ for the source. WAT cannot
  # express components, so host/sandbox invariants are exercised against this
  # build-produced, checked-in fixture.
  @fixture Path.join([
             __DIR__,
             "..",
             "..",
             "support",
             "fixtures",
             "plugins",
             "host_test_fixture.wasm"
           ])

  defp fixture_bytes, do: File.read!(@fixture)

  defp start!(slug, opts \\ []) do
    {:ok, _pid} = Host.start_plugin(slug, fixture_bytes(), opts)
    on_exit(fn -> Host.stop_plugin(slug) end)
    :ok
  end

  # The dispatcher payload shape (see Mydia.Plugins.build_payload/1). The fixture
  # branches on the "event" key.
  defp payload(event), do: %{"event" => event, "metadata" => %{}}

  describe "call/4 — typed component boundary and pooling" do
    test "calls the typed handler export and decodes the JSON result" do
      start!("hc")
      assert {:ok, %{"first" => true}} = Host.call("hc", "handle", payload("ok"))
    end

    test "each invocation runs against a fresh instance (no shared mutable state)" do
      start!("hc-iso")
      # A reused instance would observe SEEN = true on the second call and
      # return {"first": false}. Fresh instance per call => always true.
      assert {:ok, %{"first" => true}} = Host.call("hc-iso", "handle", payload("ok"))
      assert {:ok, %{"first" => true}} = Host.call("hc-iso", "handle", payload("ok"))
    end

    test "serves concurrent invocations across the pool without cross-talk" do
      start!("hc-conc", pool_size: 4)

      results =
        1..16
        |> Task.async_stream(fn _ -> Host.call("hc-conc", "handle", payload("ok")) end,
          max_concurrency: 8,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, res} -> res end)

      assert Enum.all?(results, &match?({:ok, %{"first" => true}}, &1))
    end

    test "calling an unknown slug returns a not_found error" do
      assert {:error, %Error{type: :not_found}} = Host.call("nope", "handle", payload("ok"))
    end

    test "rejects non-component bytes at start time with a clear error" do
      assert {:error, %Error{type: :compile_failed}} =
               Host.start_plugin("not-a-component", <<0, 1, 2, 3>>)
    end
  end

  describe "sandbox (R11) — locked-down WASI-P2" do
    test "a guest sees none of the host's ambient capabilities" do
      start!("hc-env")
      # The guest reads PATH (which the host process has); locked-down WASI must
      # not leak it in.
      assert {:ok, %{"env_denied" => true}} = Host.call("hc-env", "handle", payload("probe-env"))
    end
  end

  describe "memory limiting (StoreLimits)" do
    # Wasmex 0.15 enforces StoreLimits.memory_size on a component store at
    # *instantiation* (a component whose minimum linear memory exceeds the cap is
    # refused), but not on runtime memory.grow — see Host's moduledoc residual.
    # This guards the instantiation-time cap, which is the verified guarantee.
    test "a memory cap below the component's minimum refuses the invocation" do
      start!("hc-mem")

      # 64 KiB (one page) is far below any wasip2 component's minimum memory.
      assert {:error, %Error{type: :instantiate_failed}} =
               Host.call("hc-mem", "handle", payload("ok"), memory_limit_bytes: 65_536)

      # A normal cap still serves the invocation.
      assert {:ok, %{"first" => true}} =
               Host.call("hc-mem", "handle", payload("ok"), memory_limit_bytes: 64 * 1024 * 1024)
    end
  end

  describe "guest failure modes" do
    test "a guest panic surfaces as a trap, and the pool survives" do
      start!("hc-trap")
      assert {:error, %Error{type: :trap}} = Host.call("hc-trap", "handle", payload("trap"))
      assert {:ok, %{"first" => true}} = Host.call("hc-trap", "handle", payload("ok"))
    end

    test "a guest result error surfaces as a guest_error" do
      start!("hc-err")

      assert {:error, %Error{type: :guest_error, message: msg}} =
               Host.call("hc-err", "handle", payload("error"))

      assert msg =~ "intentional guest error"
    end
  end
end
