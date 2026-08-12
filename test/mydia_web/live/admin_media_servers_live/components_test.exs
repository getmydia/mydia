defmodule MydiaWeb.AdminMediaServersLive.ComponentsTest do
  use ExUnit.Case, async: true

  # Only `render_component/2` is needed here, and importing `render/1` alongside
  # the local helpers below is noise. Matches franchise_components_test.exs.
  import Phoenix.LiveViewTest, except: [render: 1]
  import Phoenix.Component, only: [to_form: 1]

  alias Mydia.Settings.MediaServerConfig
  alias MydiaWeb.AdminMediaServersLive.Components

  defp render_modal(opts) do
    config = Keyword.get(opts, :config, %MediaServerConfig{type: :plex})

    render_component(&Components.media_server_modal/1, %{
      media_server_form: to_form(MediaServerConfig.changeset(config, %{})),
      media_server_mode: Keyword.get(opts, :mode, :new),
      plex_oauth_state: Keyword.get(opts, :oauth_state, :idle),
      plex_manual_entry: Keyword.get(opts, :manual_entry, false),
      plex_reachability: Keyword.get(opts, :reachability, :checking),
      plex_discovery: Keyword.get(opts, :discovery)
    })
  end

  defp url_input_required?(html) do
    required =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#media_server_config_url")
      |> LazyHTML.attribute("required")

    required != []
  end

  defp discovered_plex_config do
    %MediaServerConfig{
      id: "22222222-2222-2222-2222-222222222222",
      name: "Storage",
      type: :plex,
      enabled: true,
      url: nil,
      token: "acct-token",
      machine_identifier: "machine-abc",
      connections: [%{"uri" => "http://127.0.0.1:32400", "local" => true}]
    }
  end

  defp server(attrs \\ %{}) do
    struct!(
      %MediaServerConfig{
        id: "11111111-1111-1111-1111-111111111111",
        name: "Storage",
        type: :plex,
        enabled: true,
        url: "http://localhost:32400",
        token: "tok",
        connection_settings: %{}
      },
      attrs
    )
  end

  defp render_tab(servers, health) do
    render_component(&Components.media_servers_tab/1, %{
      media_servers: servers,
      media_server_health: health,
      last_runs: %{}
    })
  end

  describe "health status" do
    test "an unhealthy server renders its error as text" do
      s = server()

      html = render_tab([s], %{s.id => %{status: :unhealthy, error: "connection refused"}})

      assert html =~ ~s(data-test="health-error")
      assert html =~ "connection refused"
    end

    test "a healthy server renders no error line" do
      s = server()

      html = render_tab([s], %{s.id => %{status: :healthy}})

      refute html =~ ~s(data-test="health-error")
    end

    test "an unhealthy server with no error detail renders no error line" do
      s = server()

      html = render_tab([s], %{s.id => %{status: :unhealthy}})

      refute html =~ ~s(data-test="health-error")
    end
  end

  describe "env-configured servers" do
    defp runtime_server do
      server(%{id: "runtime::media_server::storage"})
    end

    test "an env-configured server explains itself in text" do
      s = runtime_server()

      html = render_tab([s], %{s.id => %{status: :unknown}})

      assert html =~ ~s(data-test="env-config-note")
      assert html =~ "Configured via environment variables"
    end

    test "an env-configured server offers no edit or delete control" do
      s = runtime_server()

      html = render_tab([s], %{s.id => %{status: :unknown}})

      refute html =~ "edit_media_server"
      refute html =~ "delete_media_server"
    end

    test "a normal server offers edit and delete and carries no env note" do
      s = server()

      html = render_tab([s], %{s.id => %{status: :unknown}})

      assert html =~ "edit_media_server"
      assert html =~ "delete_media_server"
      refute html =~ ~s(data-test="env-config-note")
    end
  end

  describe "media server modal, Server URL requirement" do
    # Editing a server that was added through the wizard is what regressed:
    # its url is nil by design, so a hard `required` made the modal unsavable
    # and there was no way to rename it or change its sync settings.
    test "a discovered Plex config offers the URL as an optional override" do
      html = render_modal(config: discovered_plex_config(), mode: :edit, manual_entry: true)

      assert html =~ ~s(id="media_server_config_url")
      refute url_input_required?(html)
      assert html =~ "Optional manual override"
    end

    test "a Plex config with no discovery data still requires the URL" do
      html = render_modal(manual_entry: true)

      assert url_input_required?(html)
      assert html =~ "default: 32400"
    end

    test "a Jellyfin config still requires the URL" do
      html = render_modal(config: %MediaServerConfig{type: :jellyfin})

      assert url_input_required?(html)
      assert html =~ "default: 8096"
    end

    test "the discovery path renders no URL or token inputs at all" do
      html =
        render_modal(
          config: discovered_plex_config(),
          oauth_state: :complete,
          discovery: %{name: "Storage", machine_identifier: "machine-abc", connections: []}
        )

      refute html =~ ~s(id="media_server_config_url")
      refute html =~ ~s(id="media_server_config_token")
    end
  end
end
