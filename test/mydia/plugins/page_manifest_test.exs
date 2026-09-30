defmodule Mydia.Plugins.PageManifestTest do
  use Mydia.DataCase, async: false

  alias Mydia.Plugins
  alias Mydia.Plugins.Manifest
  alias Mydia.Plugins.Plugin
  alias Mydia.Plugins.Registry
  alias Mydia.Settings
  alias MydiaWeb.AdminPluginsLive.Components

  defp page_manifest(overrides \\ %{}) do
    Map.merge(
      %{
        "slug" => "page-thing",
        "name" => "Page Thing",
        "version" => "0.1.0",
        "page" => %{"title" => "Thing", "icon" => "hero-sparkles"},
        "capabilities" => %{
          "surfaces:page" => [],
          "data:search" => [],
          "net:http" => [],
          "surfaces:write" => ["media:add", "collections:write"],
          "data:read" => ["media_request", "download", "collection"]
        },
        "settings_schema" => [
          %{
            "key" => "base_url",
            "type" => "url",
            "label" => "Server URL",
            "grants_host" => true,
            "allow_private" => true
          }
        ]
      },
      overrides
    )
  end

  test "a page-only plugin parses without events:subscribe" do
    assert {:ok, %Manifest{page: %{"title" => "Thing", "icon" => "hero-sparkles"}}} =
             Manifest.parse(page_manifest())
  end

  test "surfaces:page requires a page descriptor" do
    assert {:error, %{message: msg}} = Manifest.parse(Map.delete(page_manifest(), "page"))
    assert msg =~ "page descriptor"
  end

  test "a page descriptor requires surfaces:page" do
    manifest =
      page_manifest(%{
        "capabilities" => %{"events:subscribe" => ["media_item.added"]}
      })

    assert {:error, %{message: msg}} = Manifest.parse(manifest)
    assert msg =~ "surfaces:page"
  end

  test "the page icon must be a heroicon name" do
    manifest = page_manifest(%{"page" => %{"title" => "Thing", "icon" => "<svg>"}})
    assert {:error, %{message: msg}} = Manifest.parse(manifest)
    assert msg =~ "icon"
  end

  test "the page icon must be on the allowlist" do
    manifest = page_manifest(%{"page" => %{"title" => "Thing", "icon" => "hero-not-in-the-list"}})
    assert {:error, %{message: msg}} = Manifest.parse(manifest)
    assert msg =~ "page.icon must be one of"
  end

  test "every allowlisted page icon exists in heroicons" do
    for "hero-" <> name <- Manifest.page_icons() do
      assert File.exists?(
               Path.join(["deps", "heroicons", "optimized", "24", "outline", "#{name}.svg"])
             ),
             "#{name} is not a heroicon"
    end
  end

  test "allow_private needs a host-granting url field" do
    manifest =
      page_manifest(%{
        "settings_schema" => [
          %{"key" => "k", "type" => "string", "label" => "K", "allow_private" => true}
        ]
      })

    assert {:error, %{message: msg}} = Manifest.parse(manifest)
    assert msg =~ "allow_private"
  end

  test "events:subscribe is still required without surfaces:page" do
    manifest = %{
      "slug" => "x",
      "name" => "X",
      "version" => "1.0.0",
      "capabilities" => %{"net:http" => ["example.com"]}
    }

    assert {:error, %{message: msg}} = Manifest.parse(manifest)
    assert msg =~ "events:subscribe"
  end

  test "private_host_keys lists allow_private fields" do
    {:ok, manifest} = Manifest.parse(page_manifest())
    assert Manifest.private_host_keys(manifest) == ["base_url"]
  end

  describe "net:private grant" do
    setup do
      manifest = page_manifest()

      {:ok, config} =
        Settings.create_plugin_config(%{
          slug: "page-thing",
          name: "Page Thing",
          version: "0.1.0",
          source_url: "test",
          manifest: manifest,
          granted_capabilities: %{"net:http" => [], "surfaces:page" => []},
          enabled: false
        })

      {:ok, config: config}
    end

    test "saving a private URL setting grants that host for private egress" do
      {:ok, updated} =
        Plugins.update_settings("page-thing", %{"base_url" => "http://ollama.lan:11434/v1"})

      assert updated.granted_capabilities["net:http"] == ["ollama.lan"]
      assert updated.granted_capabilities["net:private"] == ["ollama.lan"]
    end

    test "changing the URL replaces the private host" do
      {:ok, _} = Plugins.update_settings("page-thing", %{"base_url" => "http://a.lan/v1"})
      {:ok, updated} = Plugins.update_settings("page-thing", %{"base_url" => "http://b.lan/v1"})

      assert updated.granted_capabilities["net:private"] == ["b.lan"]
      assert updated.granted_capabilities["net:http"] == ["b.lan"]
    end
  end

  test "list_pages returns enabled plugins that hold surfaces:page" do
    {:ok, manifest} = Manifest.parse(page_manifest())

    plugin =
      Plugin.from_manifest(manifest,
        granted_capabilities: %{"surfaces:page" => []},
        enabled: true
      )

    Registry.register("page-thing", plugin)
    on_exit(fn -> Registry.unregister("page-thing") end)

    assert %{slug: "page-thing", title: "Thing", icon: "hero-sparkles"} in Plugins.list_pages()
  end

  test "Plugin.private_hosts reads the net:private grant" do
    {:ok, manifest} = Manifest.parse(page_manifest())

    plugin = Plugin.from_manifest(manifest, granted_capabilities: %{"net:private" => ["a.lan"]})
    assert Plugin.private_hosts(plugin) == ["a.lan"]
    assert Plugin.private_hosts(Plugin.from_manifest(manifest)) == []
  end

  describe "admin capability rendering" do
    test "new capabilities get a real label and icon" do
      for class <- ["surfaces:page", "data:search", "net:private"] do
        label = Components.capability_label(class, ["ollama.lan"])
        refute label =~ "(none)"
        refute label =~ "#{class}:"
        refute Components.capability_icon(class) == "hero-key"
      end

      assert Components.capability_label("net:private", ["ollama.lan"]) =~ "ollama.lan"
      assert Components.capability_label("surfaces:write", ["media:add"]) =~ "media"
    end

    test "private-network access and page writes are sensitive" do
      assert Components.sensitive_capability?("net:private")
      assert Components.sensitive_capability?("data:search")
      refute Components.sensitive_capability?("surfaces:page")
    end
  end
end
