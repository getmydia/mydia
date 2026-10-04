defmodule Mydia.Jobs.PluginUpdateCheckTest do
  use Mydia.DataCase, async: false

  import Mydia.MinisignFixtures

  alias Mydia.Jobs.PluginUpdateCheck
  alias Mydia.Plugins.Index.{Signature, Source}
  alias Mydia.Plugins.Sources

  setup do
    bypass = Bypass.open()
    keys = keypair()

    {:ok, row} =
      Sources.add_source(%{url: "https://fixture.test/index.json", public_key: keys.public})

    {:ok, key} = Signature.parse_public_key(keys.public)

    source = %Source{
      id: row.id,
      url: "http://allowed.test:#{bypass.port}/index.json",
      name: "Fixture",
      public_key: key
    }

    {:ok, bypass: bypass, keys: keys, row: row, source: source}
  end

  defp catalog_json(version, keys) do
    Jason.encode!(%{
      "version" => 2,
      "name" => "Fixture",
      "public_key" => keys.public,
      "plugins" => [
        %{
          "package_url" => "http://allowed.test/p.wasm",
          "integrity" => "sha256:ab",
          "manifest" => %{
            "slug" => "webhook-notifier",
            "name" => "Webhook Notifier",
            "version" => version,
            "capabilities" => %{"events:subscribe" => ["media_item.added"]}
          }
        }
      ]
    })
  end

  # Serves the catalog and its detached signature, as `serve_signed/5` does in
  # the index tests.
  defp serve_signed(bypass, keys, version) do
    body = catalog_json(version, keys)
    Bypass.stub(bypass, "GET", "/index.json", fn conn -> Plug.Conn.resp(conn, 200, body) end)

    Bypass.stub(bypass, "GET", "/index.json.minisig", fn conn ->
      Plug.Conn.resp(conn, 200, sign(body, keys))
    end)
  end

  defp install(row, version) do
    {:ok, _} =
      Mydia.Settings.create_plugin_config(%{
        slug: "webhook-notifier",
        name: "Webhook Notifier",
        version: version,
        source_url: "https://fixture.test/p.wasm",
        plugin_source_id: row.id
      })
  end

  defp check_opts(source) do
    [
      sources: [source],
      allow_private: true,
      resolver: fn _ -> {:ok, [{127, 0, 0, 1}]} end
    ]
  end

  test "perform/1 is a no-op when nothing is installed (no network)" do
    assert :ok = PluginUpdateCheck.perform(%Oban.Job{args: %{}})
  end

  test "check_for_updates emits a plugin.update_available event for a newer version", %{
    bypass: bypass,
    keys: keys,
    row: row,
    source: source
  } do
    install(row, "1.0.0")
    serve_signed(bypass, keys, "1.5.0")

    updates = Mydia.Plugins.check_for_updates(check_opts(source))

    assert [%{slug: "webhook-notifier", current: "1.0.0", latest: "1.5.0"}] = updates

    events = Mydia.Events.list_events(category: "plugin", type: "plugin.update_available")
    assert Enum.any?(events, &(&1.actor_id == "webhook-notifier"))
  end

  test "no update event when the installed version is current", %{
    bypass: bypass,
    keys: keys,
    row: row,
    source: source
  } do
    install(row, "1.5.0")
    serve_signed(bypass, keys, "1.5.0")

    assert [] = Mydia.Plugins.check_for_updates(check_opts(source))
  end
end
