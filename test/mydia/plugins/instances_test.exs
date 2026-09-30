defmodule Mydia.Plugins.InstancesTest do
  use Mydia.DataCase, async: true

  alias Mydia.Plugins.Instance
  alias Mydia.Plugins.Instances
  alias Mydia.Settings

  defp plugin_config(slug) do
    {:ok, config} =
      Settings.create_plugin_config(%{
        slug: slug,
        name: "Plugin #{slug}",
        version: "1.0.0",
        enabled: true,
        settings: %{"api_base" => "https://example.test"}
      })

    config
  end

  describe "create/2 and list/1" do
    test "creates instances for a slug and lists them by name" do
      config = plugin_config("multi")

      {:ok, b} = Instances.create("multi", %{name: "Bedroom", settings: %{"url" => "http://b"}})
      {:ok, a} = Instances.create("multi", %{name: "Attic"})

      assert a.plugin_config_id == config.id
      assert a.enabled
      assert a.approved_endpoints == []
      assert Enum.map(Instances.list("multi"), & &1.id) == [a.id, b.id]
    end

    test "requires a name" do
      plugin_config("multi")
      assert {:error, changeset} = Instances.create("multi", %{name: ""})
      assert %{name: [_ | _]} = errors_on(changeset)
    end

    test "runtime_key is unique per slug but nil never collides" do
      plugin_config("multi")
      {:ok, _} = Instances.create("multi", %{name: "A"})
      {:ok, _} = Instances.create("multi", %{name: "B"})
      {:ok, rt} = Instances.create("multi", %{name: "Declared", runtime_key: "Declared"})
      assert rt.runtime_key == "Declared"

      assert {:error, changeset} =
               Instances.create("multi", %{name: "Again", runtime_key: "Declared"})

      assert %{plugin_slug: [_ | _]} = errors_on(changeset)
    end
  end

  describe "default_instance/1" do
    test "creates the default instance once, named after the plugin" do
      plugin_config("single")

      first = Instances.default_instance("single")
      assert %Instance{name: "Plugin single", plugin_slug: "single"} = first
      assert Instances.default_instance("single").id == first.id
      assert length(Instances.list("single")) == 1
    end
  end

  describe "list_enabled/1" do
    test "skips disabled instances" do
      plugin_config("multi")
      {:ok, on} = Instances.create("multi", %{name: "On"})
      {:ok, _off} = Instances.create("multi", %{name: "Off", enabled: false})

      assert Enum.map(Instances.list_enabled("multi"), & &1.id) == [on.id]
    end
  end

  describe "approve_endpoints/2 and remove_endpoint/2" do
    test "unions endpoints with string keys and integer ports, without duplicates" do
      plugin_config("multi")
      {:ok, inst} = Instances.create("multi", %{name: "Den"})

      {:ok, inst} =
        Instances.approve_endpoints(inst, [
          %{scheme: "http", host: "192.168.1.20", port: 32400},
          %{"scheme" => "HTTPS", "host" => "Box.Local", "port" => "32400"}
        ])

      {:ok, inst} =
        Instances.approve_endpoints(inst, [
          %{"scheme" => "http", "host" => "192.168.1.20", "port" => 32400}
        ])

      assert inst.approved_endpoints == [
               %{"scheme" => "http", "host" => "192.168.1.20", "port" => 32400},
               %{"scheme" => "https", "host" => "box.local", "port" => 32400}
             ]

      {:ok, inst} =
        Instances.remove_endpoint(inst, %{scheme: "http", host: "192.168.1.20", port: 32400})

      assert inst.approved_endpoints == [
               %{"scheme" => "https", "host" => "box.local", "port" => 32400}
             ]

      assert Instances.get!(inst.id).approved_endpoints == inst.approved_endpoints
    end
  end

  describe "approve_endpoints/2 with unusable endpoints" do
    test "returns an error instead of raising on a bad or missing port" do
      plugin_config("multi")
      {:ok, inst} = Instances.create("multi", %{name: "Den"})

      for port <- [nil, "abc", "", 0, 70_000, 1.5] do
        assert {:error, {:invalid_endpoint, _}} =
                 Instances.approve_endpoints(inst, [
                   %{"scheme" => "http", "host" => "plex.lan", "port" => port}
                 ])
      end

      assert {:error, {:invalid_endpoint, _}} =
               Instances.replace_endpoints(inst, [
                 %{"scheme" => "ftp", "host" => "plex.lan", "port" => 21}
               ])

      assert Instances.get!(inst.id).approved_endpoints == []
    end

    test "remove_endpoint/2 tolerates a bad port" do
      plugin_config("multi")
      {:ok, inst} = Instances.create("multi", %{name: "Den"})

      assert {:ok, _} =
               Instances.remove_endpoint(inst, %{"scheme" => "http", "host" => "x", "port" => nil})
    end
  end

  describe "set_remote_accounts/2" do
    test "stores the proposed accounts" do
      plugin_config("multi")
      {:ok, inst} = Instances.create("multi", %{name: "Den"})

      {:ok, inst} =
        Instances.set_remote_accounts(inst, [%{id: "7", name: "Robin", admin: true}])

      assert Instances.get!(inst.id).remote_accounts == [
               %{"id" => "7", "name" => "Robin", "admin" => true}
             ]
    end
  end

  describe "multi_instance plugins have no default instance" do
    test "default_instance/1 returns nil and creates nothing" do
      {:ok, _} =
        Settings.create_plugin_config(%{
          slug: "multi-only",
          name: "Multi",
          version: "1.0.0",
          enabled: true,
          manifest: %{"slug" => "multi-only", "multi_instance" => true}
        })

      assert Instances.default_instance("multi-only") == nil
      assert Instances.list("multi-only") == []
    end
  end

  describe "merge_default_settings/2" do
    test "writes settings into a single-instance plugin's default instance" do
      plugin_config("single")
      inst = Instances.default_instance("single")

      assert :ok = Instances.merge_default_settings("single", %{"api_base" => "https://new.test"})

      assert Instances.config_for(Instances.get!(inst.id))["api_base"] == "https://new.test"
    end
  end

  describe "config_for/1" do
    test "merges the instance id into the settings" do
      plugin_config("multi")
      {:ok, inst} = Instances.create("multi", %{name: "Den", settings: %{"url" => "http://x"}})

      assert Instances.config_for(inst) == %{"url" => "http://x", "instance_id" => inst.id}
    end
  end

  describe "delete/1" do
    test "removes the instance and its kv rows" do
      plugin_config("single")
      inst = Instances.default_instance("single")
      {:ok, _} = Mydia.Plugins.Kv.set(inst.id, "k", "v")

      assert :ok = Instances.delete(inst)
      assert Instances.get(inst.id) == nil
      assert {:ok, nil} = Mydia.Plugins.Kv.get(inst.id, "k")
    end
  end
end
