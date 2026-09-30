defmodule Mydia.Plugins.InstanceRuntimeTest do
  # async: false: starts a real pool and registers in the app-wide Registry.
  use Mydia.DataCase, async: false

  alias Mydia.Plugins
  alias Mydia.Plugins.Error
  alias Mydia.Plugins.Host
  alias Mydia.Plugins.HostFunctions
  alias Mydia.Plugins.Instances
  alias Mydia.Plugins.Plugin
  alias Mydia.Plugins.Registry
  alias Mydia.Settings

  @fixture Path.expand("../../support/fixtures/plugins/host_v14_fixture.wasm", __DIR__)
  @slug "v14rt"

  defp config!(slug, manifest_extra) do
    {:ok, config} =
      Settings.create_plugin_config(%{
        slug: slug,
        name: slug,
        version: "1.0.0",
        source_url: "test",
        manifest:
          Map.merge(
            %{
              "slug" => slug,
              "name" => slug,
              "version" => "1.0.0",
              "capabilities" => %{"events:subscribe" => ["media_item.added"]}
            },
            manifest_extra
          ),
        granted_capabilities: %{"events:subscribe" => ["media_item.added"]},
        enabled: true
      })

    config
  end

  setup do
    original = Application.get_env(:mydia, :runtime_config)

    on_exit(fn ->
      if original,
        do: Application.put_env(:mydia, :runtime_config, original),
        else: Application.delete_env(:mydia, :runtime_config)
    end)

    config!(@slug, %{"multi_instance" => true, "setup" => true})

    {:ok, _} =
      Host.start_plugin(@slug, File.read!(@fixture), imports: HostFunctions.imports_for(@slug))

    plugin = %Plugin{
      slug: @slug,
      name: @slug,
      entrypoint: "handle",
      events: ["media_item.added"],
      enabled: true,
      multi_instance: true,
      setup: true
    }

    {:ok, _} = Registry.register(@slug, plugin)

    on_exit(fn ->
      Host.stop_plugin(@slug)
      Registry.clear()
    end)

    {:ok, a} =
      Instances.create(@slug, %{
        name: "Upstairs",
        settings: %{"url" => "http://a", "suggest_user_id" => "local-a"}
      })

    {:ok, b} = Instances.create(@slug, %{name: "Downstairs", settings: %{"url" => "http://b"}})

    %{plugin: plugin, a: a, b: b}
  end

  defp event, do: %{type: "config", metadata: %{}}

  test "invoke_plugin/3 injects that instance's config", %{plugin: plugin, a: a} do
    assert {:ok, %{"config" => config}} = Plugins.invoke_plugin(plugin, a, event())
    assert config["instance_id"] == a.id
    assert config["url"] == "http://a"
  end

  test "invoke_plugin/2 fans out to every enabled instance", %{plugin: plugin, a: a, b: b} do
    {:ok, _} = Instances.update(b, %{enabled: false})
    {:ok, c} = Instances.create(@slug, %{name: "Attic", settings: %{"url" => "http://c"}})

    assert {:ok, results} = Plugins.invoke_plugin(plugin, event())

    ids =
      results
      |> Enum.map(fn {:ok, %{"config" => config}} -> config["instance_id"] end)
      |> Enum.sort()

    assert ids == Enum.sort([a.id, c.id])
  end

  test "invoke_plugin_schedule/3 runs on-schedule with that instance's config", %{a: a} do
    assert {:ok, %{"scheduled" => true, "config" => %{"instance_id" => id}}} =
             Plugins.invoke_plugin_schedule(@slug, a.id)

    assert id == a.id
  end

  test "invoke_setup/3 passes the instance config to the guest", %{a: a, b: b} do
    assert {:ok, %{body: {:external_auth, _}, step: "auth"}} =
             Plugins.invoke_setup(@slug, a.id, %{
               step: "start",
               input_json: "{}",
               state_json: "{}"
             })

    pick = %{step: "pick", input_json: ~s({"option_id":"server-a"}), state_json: "{}"}

    assert {:ok, %{body: {:mapping, %{suggestions: [%{user_id: "local-a"}]}}}} =
             Plugins.invoke_setup(@slug, a.id, pick)

    assert {:ok, %{body: {:mapping, %{suggestions: []}}}} =
             Plugins.invoke_setup(@slug, b.id, pick)
  end

  test "a guest Err surfaces as a guest_error with its message", %{a: a} do
    assert {:error, %Error{type: :guest_error, message: "fixture failure"}} =
             Plugins.invoke_setup(@slug, a.id, %{step: "fail", input_json: "{}", state_json: "{}"})
  end

  test "invoke_check_health/2 returns the decoded health", %{a: a} do
    assert {:ok, %{status: :degraded, message: "fixture degraded", action: :reconnect}} =
             Plugins.invoke_check_health(@slug, a.id)
  end

  test "an unknown or foreign instance id is not found", %{a: _a} do
    assert {:error, %Error{type: :not_found}} =
             Plugins.invoke_check_health(@slug, Ecto.UUID.generate())

    assert {:error, %Error{type: :not_found}} = Plugins.invoke_check_health(@slug, "not-a-uuid")

    config!("elsewhere", %{})
    {:ok, foreign} = Instances.create("elsewhere", %{name: "Foreign"})
    assert {:error, %Error{type: :not_found}} = Plugins.invoke_check_health(@slug, foreign.id)
  end

  test "setup and health are unsupported without setup: true in the manifest", %{a: a} do
    {:ok, _} =
      Registry.register(@slug, %Plugin{
        slug: @slug,
        entrypoint: "handle",
        enabled: true,
        setup: false
      })

    assert {:error, %Error{type: :unsupported}} =
             Plugins.invoke_setup(@slug, a.id, %{
               step: "start",
               input_json: "{}",
               state_json: "{}"
             })

    assert {:error, %Error{type: :unsupported}} = Plugins.invoke_check_health(@slug, a.id)
  end

  test "ensure_default_instance/1 creates one instance for a single-instance plugin only" do
    config!("single", %{})

    assert :ok = Plugins.ensure_default_instance(%Plugin{slug: "single"})
    assert :ok = Plugins.ensure_default_instance(%Plugin{slug: "single"})
    assert [_one] = Instances.list("single")

    assert :ok = Plugins.ensure_default_instance(%Plugin{slug: @slug, multi_instance: true})
    assert length(Instances.list(@slug)) == 2
  end
end
