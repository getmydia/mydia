defmodule Mydia.Plugins.HostFunctionsKvTest do
  use Mydia.DataCase, async: true

  alias Mydia.Plugins.Error
  alias Mydia.Plugins.HostFunctions
  alias Mydia.Plugins.Instances
  alias Mydia.Plugins.Kv
  alias Mydia.Plugins.Plugin
  alias Mydia.Settings

  @slug "kv_host_tester"

  setup do
    {:ok, _} =
      Settings.create_plugin_config(%{
        slug: @slug,
        name: @slug,
        version: "1.0.0",
        source_url: "test",
        manifest: %{
          "slug" => @slug,
          "name" => @slug,
          "version" => "1.0.0",
          "capabilities" => %{"events:subscribe" => ["media_item.added"], "state:kv" => []}
        },
        granted_capabilities: %{"state:kv" => []},
        enabled: true
      })

    {:ok, instance} = Instances.create(@slug, %{name: "one"})

    granted = %Plugin{
      slug: @slug,
      name: @slug,
      enabled: true,
      granted_capabilities: %{"state:kv" => []}
    }

    ungranted = %Plugin{granted | granted_capabilities: %{}}
    {:ok, instance: instance, granted: granted, ungranted: ungranted}
  end

  test "kv_set_many then kv_list round-trip through WIT shapes", %{instance: i, granted: p} do
    entries = [%{key: "map/1", value: "a"}, %{key: "map/2", value: "b"}, %{key: "x", value: "c"}]
    assert :ok = HostFunctions.kv_set_many(p, i, entries)

    assert {:ok, %{entries: listed, "next-cursor": :none}} =
             HostFunctions.kv_list(p, i, "map/", :none)

    assert listed == [%{key: "map/1", value: "a"}, %{key: "map/2", value: "b"}]
  end

  test "kv_list hands back an opaque cursor as option<string>", %{instance: i, granted: p} do
    :ok =
      Kv.set_many(i.id, for(n <- 1..201, do: {"k/#{String.pad_leading("#{n}", 3, "0")}", "v"}))

    assert {:ok, %{"next-cursor": {:some, cursor}}} = HostFunctions.kv_list(p, i, "k/", :none)

    assert {:ok, %{entries: [%{key: "k/201"}], "next-cursor": :none}} =
             HostFunctions.kv_list(p, i, "k/", {:some, cursor})
  end

  test "kv_get/kv_set/kv_delete are instance-scoped", %{instance: i, granted: p} do
    {:ok, other} = Instances.create(@slug, %{name: "two"})
    assert {:ok, true} = HostFunctions.kv_set(p, i, "k", "v")
    assert {:ok, {:some, "v"}} = HostFunctions.kv_get(p, i, "k")
    assert {:ok, :none} = HostFunctions.kv_get(p, other, "k")
    assert {:ok, true} = HostFunctions.kv_delete(p, i, "k")
    assert {:ok, :none} = HostFunctions.kv_get(p, i, "k")
  end

  test "kv_set_many with no entries succeeds", %{instance: i, granted: p} do
    assert :ok = HostFunctions.kv_set_many(p, i, [])
  end

  test "without state:kv every store call is denied", %{instance: i, ungranted: p} do
    assert {:error, %Error{type: :capability_denied}} = HostFunctions.kv_list(p, i, "", :none)

    assert {:error, %Error{type: :capability_denied}} =
             HostFunctions.kv_set_many(p, i, [%{key: "a", value: "b"}])
  end
end
