defmodule Mydia.Plugins.ContractV16Test do
  # async: false: starts real pools under the app-wide PoolRegistry.
  use Mydia.DataCase, async: false

  alias Mydia.Plugins.Host
  alias Mydia.Plugins.HostFunctions

  @fixtures Path.join([__DIR__, "..", "..", "support", "fixtures", "plugins"])

  defp start(slug, file) do
    bytes = File.read!(Path.join(@fixtures, file))
    {:ok, _} = Host.start_plugin(slug, bytes, imports: HostFunctions.imports_for(slug))
    on_exit(fn -> Host.stop_plugin(slug) end)
  end

  test "detects a 1.6 guest and still detects a 1.5 one" do
    start("v16-detect", "shelf_fixture.wasm")
    start("v15-still", "host_v15_fixture.wasm")

    assert Host.contract_version("v16-detect") == :v16
    assert Host.contract_version("v15-still") == :v15
  end

  test "typed exports are available from 1.5 on" do
    start("v16-typed", "shelf_fixture.wasm")
    start("v15-typed", "host_v15_fixture.wasm")
    start("v14-typed", "page_fixture.wasm")

    assert Host.typed_exports?("v16-typed")
    assert Host.typed_exports?("v15-typed")
    refute Host.typed_exports?("v14-typed")
  end

  test "a 1.6 guest handles an event" do
    start("v16-event", "shelf_fixture.wasm")

    assert {:ok, %{}} = Host.call("v16-event", "handle", %{"event" => "media_item.added"})
  end

  test "the host publishes the 1.6 and 1.5 namespaces with the same functions" do
    imports =
      HostFunctions.imports_for("any").(%{
        slug: "any",
        instance_id: nil,
        invocation_id: "i",
        test_run: false,
        handler: :on_event,
        acting_user_id: nil,
        role: nil,
        session_id: nil
      })

    v16 = Map.fetch!(imports, "mydia:plugin/host@1.6.0")
    v15 = Map.fetch!(imports, "mydia:plugin/host@1.5.0")

    assert Map.keys(v16) == Map.keys(v15)
    assert Map.has_key?(v16, "kv-list")
  end
end
