defmodule Mydia.Plugins.Notifier.DeliveryTest do
  # async: false — runs the real bundled guest in a pool under the app-wide
  # PoolRegistry. DataCase shares the sandbox connection (async: false), so the
  # guest's data:read host function can reach the DB for enrichment.
  use Mydia.DataCase, async: false

  import Mydia.MediaFixtures

  alias Mydia.Plugins.Host
  alias Mydia.Plugins.HostFunctions
  alias Mydia.Plugins.Instances
  alias Mydia.Plugins.Manifest
  alias Mydia.Plugins.Notifier.Delivery
  alias Mydia.Plugins.Plugin
  alias Mydia.Plugins.Registry
  alias Mydia.Settings

  @slug "webhook-notifier"

  defp bundled_wasm,
    do: File.read!(Application.app_dir(:mydia, "priv/plugins/webhook_notifier.wasm"))

  defp bundled_manifest,
    do: File.read!(Application.app_dir(:mydia, "priv/plugins/webhook_notifier.json"))

  # Starts the real notifier guest with a grant for the Bypass host and the
  # loopback gate seam, plus a config row carrying the webhook URL.
  defp start_notifier!(bypass, opts \\ []) do
    {:ok, manifest} = Manifest.parse(bundled_manifest())
    host = Keyword.get(opts, :webhook_host, "webhook.test")
    granted_host = Keyword.get(opts, :granted_host, host)
    extra_settings = Keyword.get(opts, :settings, %{})

    grants = %{
      "events:subscribe" => manifest.events,
      "net:http" => [granted_host],
      "data:read" => ["media_item"]
    }

    settings =
      Map.merge(
        %{
          "webhook_url" => "http://#{host}:#{bypass.port}/hook",
          "delivery" => "durable"
        },
        extra_settings
      )

    {:ok, _} =
      Settings.create_plugin_config(%{
        slug: @slug,
        name: manifest.name,
        version: manifest.version,
        manifest: %{"capabilities" => manifest.capabilities},
        wasm_module: bundled_wasm(),
        granted_capabilities: grants,
        enabled: true,
        settings: settings
      })

    descriptor =
      Plugin.from_manifest(manifest,
        granted_capabilities: grants,
        enabled: true,
        delivery: :durable
      )

    {:ok, _} = Registry.register(@slug, descriptor)

    imports =
      HostFunctions.imports_for(@slug,
        allow_private: true,
        resolver: fn _ -> {:ok, [{127, 0, 0, 1}]} end
      )

    {:ok, _} = Host.start_plugin(@slug, bundled_wasm(), imports: imports)
    on_exit(fn -> Host.stop_plugin(@slug) end)
    :ok
  end

  defp job(payload), do: %Oban.Job{args: %{"slug" => @slug, "payload" => payload}}

  defp added_payload(media_item) do
    %{
      "event" => "media_item.added",
      "category" => "media",
      "resource_type" => "media_item",
      "resource_id" => media_item.id,
      "metadata" => %{"title" => media_item.title}
    }
  end

  setup do
    Registry.clear()
    on_exit(&Registry.clear/0)
    {:ok, bypass: Bypass.open()}
  end

  test "R16/F3: a media_item.added event drives a webhook POST with the expected payload", %{
    bypass: bypass
  } do
    start_notifier!(bypass)
    item = media_item_fixture(%{title: "Interstellar"})

    test_pid = self()

    Bypass.expect_once(bypass, "POST", "/hook", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:webhook_body, body})
      Plug.Conn.resp(conn, 204, "")
    end)

    assert :ok = Delivery.perform(job(added_payload(item)))

    assert_receive {:webhook_body, body}
    assert body =~ "Interstellar"
    assert body =~ "Added to library"
  end

  test "enriches the payload via data:read (overview from the media item)", %{bypass: bypass} do
    start_notifier!(bypass)

    item =
      media_item_fixture(%{
        title: "Dune",
        metadata: %{overview: "A noble family takes control of a desert planet."}
      })

    test_pid = self()

    Bypass.expect_once(bypass, "POST", "/hook", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:webhook_body, body})
      Plug.Conn.resp(conn, 204, "")
    end)

    assert :ok = Delivery.perform(job(added_payload(item)))
    assert_receive {:webhook_body, body}
    assert body =~ "desert planet"
  end

  test "download.completed also triggers delivery", %{bypass: bypass} do
    start_notifier!(bypass)
    Bypass.expect_once(bypass, "POST", "/hook", fn conn -> Plug.Conn.resp(conn, 200, "") end)

    payload = %{
      "event" => "download.completed",
      "category" => "downloads",
      "metadata" => %{"title" => "Some.Release.1080p"}
    }

    assert :ok = Delivery.perform(job(payload))
  end

  test "returns an error (for Oban retry) when the webhook responds 5xx", %{bypass: bypass} do
    start_notifier!(bypass)
    item = media_item_fixture()
    Bypass.expect(bypass, "POST", "/hook", fn conn -> Plug.Conn.resp(conn, 500, "boom") end)

    assert {:error, _} = Delivery.perform(job(added_payload(item)))
  end

  test "AE2: a webhook host that is not on the grant is blocked by the gate", %{bypass: bypass} do
    # Granted discord.com, but the configured webhook points at webhook.test.
    start_notifier!(bypass, granted_host: "discord.com", webhook_host: "webhook.test")
    item = media_item_fixture()

    # The gate denies before any request, so Bypass is never hit and delivery fails.
    assert {:error, _} = Delivery.perform(job(added_payload(item)))
  end

  describe "ntfy target (R5, R6)" do
    test "POSTs a plain-text body with Title/Priority/Tags and Bearer auth headers", %{
      bypass: bypass
    } do
      start_notifier!(bypass,
        settings: %{
          "target" => "ntfy",
          "ntfy_priority" => "4",
          "ntfy_tags" => "tada,movie",
          "ntfy_token" => "tk_secret"
        }
      )

      item = media_item_fixture(%{title: "Interstellar"})
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/hook", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:ntfy, body, conn.req_headers})
        Plug.Conn.resp(conn, 200, "")
      end)

      assert :ok = Delivery.perform(job(added_payload(item)))
      assert_receive {:ntfy, body, headers}

      # The message is the plain body — not the Discord JSON embed.
      assert body =~ "Added to library"
      refute body =~ "embeds"
      assert {"title", "Interstellar"} in headers
      assert {"priority", "4"} in headers
      assert {"tags", "tada,movie"} in headers
      assert {"authorization", "Bearer tk_secret"} in headers
      assert {"content-type", "text/plain"} in headers
    end

    test "omits optional headers when only the URL is configured", %{bypass: bypass} do
      start_notifier!(bypass, settings: %{"target" => "ntfy"})
      item = media_item_fixture(%{title: "Dune"})
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/hook", fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:headers, conn.req_headers})
        Plug.Conn.resp(conn, 200, "")
      end)

      assert :ok = Delivery.perform(job(added_payload(item)))
      assert_receive {:headers, headers}

      keys = Enum.map(headers, fn {k, _} -> k end)
      assert {"title", "Dune"} in headers
      refute "priority" in keys
      refute "tags" in keys
      refute "authorization" in keys
    end

    test "strips CR/LF from operator header values (no header injection)", %{bypass: bypass} do
      start_notifier!(bypass,
        settings: %{"target" => "ntfy", "ntfy_priority" => "4\r\nX-Injected: evil"}
      )

      item = media_item_fixture(%{title: "Dune"})
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/hook", fn conn ->
        send(test_pid, {:headers, conn.req_headers})
        Plug.Conn.resp(conn, 200, "")
      end)

      assert :ok = Delivery.perform(job(added_payload(item)))
      assert_receive {:headers, headers}

      priority = Enum.find_value(headers, fn {k, v} -> if k == "priority", do: v end)
      assert priority == "4X-Injected: evil"
      refute Enum.any?(headers, fn {k, _} -> k == "x-injected" end)
    end

    test "an ntfy host not on the grant is still blocked by the gate", %{bypass: bypass} do
      start_notifier!(bypass,
        granted_host: "discord.com",
        webhook_host: "ntfy.test",
        settings: %{"target" => "ntfy"}
      )

      item = media_item_fixture()
      assert {:error, _} = Delivery.perform(job(added_payload(item)))
    end
  end

  test "a job for a deleted instance is cancelled without delivering or creating an instance",
       %{bypass: bypass} do
    start_notifier!(bypass)
    item = media_item_fixture()

    {:ok, gone} = Instances.create(@slug, %{name: "Removed"})
    :ok = Instances.delete(gone)
    before_ids = @slug |> Instances.list() |> Enum.map(& &1.id) |> Enum.sort()

    # Bypass fails the test on any unexpected request, so a delivery would show.
    job = %Oban.Job{
      args: %{
        "slug" => @slug,
        "instance_id" => gone.id,
        "payload" => added_payload(item)
      }
    }

    assert {:cancel, _} = Delivery.perform(job)
    assert @slug |> Instances.list() |> Enum.map(& &1.id) |> Enum.sort() == before_ids
  end
end
