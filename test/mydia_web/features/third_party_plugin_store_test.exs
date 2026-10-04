defmodule MydiaWeb.Features.ThirdPartyPluginStoreTest do
  @moduledoc """
  The whole third-party plugin source journey through the admin UI: add a
  signed source, install a plugin from it, then take the update it publishes.
  """
  use MydiaWeb.FeatureCase, async: false

  alias Mydia.MinisignFixtures
  alias Mydia.Plugins.Host
  alias Mydia.Plugins.Index.Signature
  alias Mydia.Plugins.Registry
  alias Mydia.Plugins.Sources
  alias Mydia.PluginStoreFixture
  alias Mydia.Settings

  @guest_fixture Path.expand("../../support/fixtures/plugins/host_test_fixture.wasm", __DIR__)
  @slug "lantern-tools"

  @manifest %{
    "slug" => @slug,
    "name" => "Lantern Tools",
    "version" => "1.0.0",
    "description" => "Fixture plugin served by a test-only third-party source",
    "author" => "Lantern Test Works",
    # At least one capability: an install with an empty grant stays inactive,
    # and this test has to see the plugin running.
    "capabilities" => %{"events:subscribe" => ["media_item.added"]}
  }

  setup do
    # Plugins.install/2 reloads :runtime_config from YAML, DB and env.
    original_runtime = Application.get_env(:mydia, :runtime_config)
    original_seam = Application.get_env(:mydia, :plugin_index_opts)

    # Loopback http is allowed and only localhost resolves, so the official
    # index fails at the gate instead of reaching the internet. Browse keeps
    # the entries of the sources that answered.
    Application.put_env(:mydia, :plugin_index_opts,
      allow_private: true,
      resolver: fn
        "localhost" -> {:ok, [{127, 0, 0, 1}]}
        _ -> {:error, :nxdomain}
      end
    )

    on_exit(fn ->
      restore(:runtime_config, original_runtime)
      restore(:plugin_index_opts, original_seam)
      Host.stop_plugin(@slug)
      Registry.unregister(@slug)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:mydia, key)
  defp restore(key, value), do: Application.put_env(:mydia, key, value)

  @tag :feature
  test "adds a signed source, installs from it and takes its update", %{session: session} do
    wasm = File.read!(@guest_fixture)
    keys = MinisignFixtures.keypair()
    {:ok, key} = Signature.parse_public_key(keys.public)
    store = PluginStoreFixture.start(Bypass.open(), keys)
    :ok = PluginStoreFixture.publish(store, @manifest, wasm)

    login_as_admin(session)
    visit_liveview(session, "/admin/plugins")

    # Add the source. The preview shows the fingerprint to compare.
    session
    |> click(Query.css("#add-source"))
    |> fill_in(Query.css("#add-source-form input[name='url']"),
      with: PluginStoreFixture.url(store)
    )
    |> click(Query.css("#add-source-form button[type='submit']"))
    |> assert_has(Query.css("#source-preview", text: Signature.fingerprint(key)))
    |> click(Query.css("#confirm-source"))
    |> assert_has(Query.css("#plugin-sources tr", text: "Lantern Plugins"))

    [source] = Sources.list_sources()
    row = "src-#{source.id}-#{@slug}"

    # The store lists the plugin as third-party.
    session
    |> click(Query.css("#browse-store"))
    |> assert_has(Query.css("#catalog-third-party-#{row}"))
    |> assert_has(Query.css("#install-#{row}", text: "Install"))

    # Install through the third-party warning. The plugin runs.
    session
    |> click(Query.css("#install-#{row}"))
    |> assert_has(Query.css("#approval-publisher-warning"))
    |> click(Query.css("#confirm-approval"))
    |> assert_has(Query.css("#plugin-row-#{@slug}", text: "v1.0.0"))

    assert Registry.registered?(@slug)
    assert Sources.origin(Settings.get_plugin_config_by_slug(@slug)) == {:source, source.id}

    # The source ships 2.0.0, and the store offers it as an update from itself.
    :ok = PluginStoreFixture.publish(store, %{@manifest | "version" => "2.0.0"}, wasm)

    session
    |> click(Query.css("#browse-store"))
    |> click(Query.css("#install-#{row}", text: "Update to v2.0.0"))
    |> click(Query.css("#confirm-approval"))
    |> assert_has(Query.css("#plugin-row-#{@slug}", text: "v2.0.0"))

    assert Registry.registered?(@slug)
    assert Sources.origin(Settings.get_plugin_config_by_slug(@slug)) == {:source, source.id}
  end
end
