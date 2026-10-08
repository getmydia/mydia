defmodule MydiaWeb.PluginInstanceComponentsTest do
  use MydiaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Mydia.Plugins.AccountLink
  alias Mydia.Plugins.Instance
  alias Mydia.Plugins.Plugin
  alias MydiaWeb.PluginInstanceComponents

  defp plugin, do: %Plugin{slug: "plex", name: "Plex", category: "media_server", setup: true}

  defp instance(attrs \\ %{}) do
    struct(
      %Instance{
        id: "11111111-1111-1111-1111-111111111111",
        plugin_slug: "plex",
        name: "Living Room",
        enabled: true,
        settings: %{},
        approved_endpoints: [
          %{"scheme" => "http", "host" => "192.168.1.20", "port" => 32400}
        ],
        source: :db
      },
      attrs
    )
  end

  defp render_card(attrs) do
    defaults = %{
      plugin: plugin(),
      instance: instance(),
      health: %{status: :ok, message: nil, action: nil, checked_at: nil},
      last_run: nil,
      links: []
    }

    render_component(&PluginInstanceComponents.plugin_instance_row/1, Map.merge(defaults, attrs))
    |> LazyHTML.from_fragment()
  end

  defp has?(doc, selector), do: LazyHTML.query(doc, selector) |> Enum.count() > 0

  test "a DB instance renders every action and its endpoints" do
    doc = render_card(%{})
    id = instance().id

    assert has?(doc, "#plugin-instance-#{id}")
    assert has?(doc, "#plugin-instance-sync-#{id}")
    assert has?(doc, "#plugin-instance-test-#{id}")
    assert has?(doc, "#plugin-instance-reconnect-#{id}")
    assert has?(doc, "#plugin-instance-accounts-#{id}")
    assert has?(doc, "#plugin-instance-toggle-#{id}")
    assert has?(doc, "#plugin-instance-delete-#{id}")
    assert has?(doc, "#plugin-instance-endpoint-#{id}-0")
    assert has?(doc, "#plugin-instance-endpoint-remove-#{id}-0")
  end

  test "a runtime instance is read-only but can still sync and test" do
    doc = render_card(%{instance: instance(%{source: :runtime})})
    id = instance().id

    assert has?(doc, "#plugin-instance-sync-#{id}:not([disabled])")
    assert has?(doc, "#plugin-instance-test-#{id}:not([disabled])")
    assert has?(doc, "#plugin-instance-delete-#{id}[disabled]")
    assert has?(doc, "#plugin-instance-toggle-#{id}[disabled]")
    assert has?(doc, "#plugin-instance-reconnect-#{id}[disabled]")
    assert has?(doc, ".badge-primary .hero-lock-closed")
    refute has?(doc, "#plugin-instance-endpoint-remove-#{id}-0")
  end

  test "a health action renders a button naming it" do
    doc =
      render_card(%{
        health: %{
          status: :unreachable,
          message: "Server moved",
          action: :confirm_endpoints,
          checked_at: nil
        }
      })

    button = LazyHTML.query(doc, "#plugin-instance-health-action-#{instance().id}")
    assert LazyHTML.text(button) =~ "Confirm new addresses"
  end

  test "a partial run renders whether or not its counts carry errors" do
    with_errors =
      render_card(%{last_run: %{status: :partial, error: nil, counts: %{"errors" => 3}}})

    without = render_card(%{last_run: %{status: :partial, error: nil, counts: %{"pulled" => 1}}})
    nil_counts = render_card(%{last_run: %{status: :partial, error: nil, counts: nil}})

    assert LazyHTML.text(with_errors) =~ "Partly synced: 3 errors"
    assert LazyHTML.text(without) =~ "Partly synced"
    refute LazyHTML.text(without) =~ "errors"
    assert LazyHTML.text(nil_counts) =~ "Partly synced"
  end

  test "linked accounts are listed by remote username" do
    link = %AccountLink{
      id: "22222222-2222-2222-2222-222222222222",
      role: :user,
      status: :active,
      external_username: "harbor_kid"
    }

    doc = render_card(%{links: [link]})
    assert LazyHTML.text(doc) =~ "harbor_kid"
  end

  test "the deprecation banner names each legacy server and the replacement form" do
    doc =
      render_component(&PluginInstanceComponents.plex_deprecation_banner/1, %{
        declarations: [%{name: "Glass Orchard Server"}, %{name: "Harbor Lights Server"}]
      })
      |> LazyHTML.from_fragment()

    text = doc |> LazyHTML.filter("#plex-deprecation-banner") |> LazyHTML.text()
    assert text =~ "Glass Orchard Server"
    assert text =~ "Harbor Lights Server"
    assert text =~ "PLUGIN_PLEX_"
    assert text =~ "plugin_instances"
  end

  test "the deprecation banner renders nothing without legacy declarations" do
    html =
      render_component(&PluginInstanceComponents.plex_deprecation_banner/1, %{declarations: []})

    refute html =~ "plex-deprecation-banner"
  end
end
