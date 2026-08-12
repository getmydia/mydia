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

  describe "media server modal, submit button availability" do
    defp submit_disabled?(html) do
      disabled =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#media-server-submit")
        |> LazyHTML.attribute("disabled")

      disabled != []
    end

    # New + Plex + no manual entry + not yet complete means there is no url
    # input on screen at all: submitting would fail on a changeset error
    # pinned to :url, which nothing on the page shows. Disable Add Server
    # rather than let that happen silently.
    test "Add Server is disabled for a new Plex server before the wizard completes" do
      html = render_modal(mode: :new, oauth_state: :idle, manual_entry: false)

      assert submit_disabled?(html)
    end

    test "Add Server is enabled once the Plex wizard reaches the review step" do
      html =
        render_modal(
          mode: :new,
          oauth_state: :complete,
          manual_entry: false,
          discovery: %{name: "Storage", machine_identifier: "machine-abc", connections: []}
        )

      refute submit_disabled?(html)
    end

    test "Save Changes stays enabled in edit mode even before the wizard completes" do
      # In edit/reconnect mode the base struct already carries the discovery
      # data, so the same visual state that blocks a new save can save
      # successfully here.
      html =
        render_modal(
          config: discovered_plex_config(),
          mode: :edit,
          oauth_state: :idle,
          manual_entry: false
        )

      refute submit_disabled?(html)
    end
  end

  describe "media server modal, Enabled toggle form association" do
    # The Enabled toggle sits in the modal header, above where <.form> opens,
    # so it is not a descendant of the form element. Without an explicit
    # `form="media-server-form"` attribute the browser never submits it: the
    # hidden false-sentinel is dropped and the checkbox is dropped, so
    # `enabled` never reaches phx-change or phx-submit at all.
    defp enabled_inputs(html) do
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s([name="media_server_config[enabled]"]))
    end

    test "both the hidden sentinel and the checkbox are associated with the form by id" do
      html = render_modal(mode: :edit)

      form_attrs =
        html
        |> enabled_inputs()
        |> LazyHTML.attribute("form")

      assert form_attrs == ["media-server-form", "media-server-form"]
    end
  end

  describe "media server modal, discovery review panel" do
    defp discovery_map do
      %{
        name: "Storage",
        machine_identifier: "machine-abc",
        connections: [
          %{uri: "https://10-0-0-4.abc.plex.direct:32400", local: true, relay: false},
          %{uri: "https://relay.plex.direct:443", local: false, relay: true}
        ]
      }
    end

    test "the review panel names the server and its machine identifier" do
      html = render_modal(oauth_state: :complete, discovery: discovery_map())

      assert html =~ ~s(data-test="plex-discovery-summary")
      assert html =~ "Storage"
      assert html =~ "machine-abc"
    end

    test "the review panel lists the discovered addresses with their badges" do
      html = render_modal(oauth_state: :complete, discovery: discovery_map())

      # `simplify_plex_url("https://relay.plex.direct:443")` renders as
      # "relay:443" in the connection line itself, so a loose `html =~
      # "relay"` passes even with the relay badge deleted. Assert on the
      # DaisyUI badge classes the markup actually uses instead.
      document = LazyHTML.from_fragment(html)

      refute Enum.empty?(LazyHTML.query(document, ".badge-info"))
      refute Enum.empty?(LazyHTML.query(document, ".badge-warning"))
    end

    test "the review panel offers a way back but collects no input" do
      html = render_modal(oauth_state: :complete, discovery: discovery_map())

      assert html =~ "cancel_plex_oauth"
      refute html =~ ~s(id="media_server_config_url")
    end

    # The review step already reports reachability on its own, so a second
    # button asking the same question is noise. (It used to be worse than noise:
    # the probe config was built from url and token alone, so on the discovery
    # path it answered "URL is required" every time. It now carries the
    # discovered connections, but the panel still says it better.)
    test "Test Connection is hidden on the review step" do
      html = render_modal(oauth_state: :complete, discovery: discovery_map())

      refute html =~ "test_media_server_connection"
    end

    test "Test Connection is still offered everywhere else" do
      html = render_modal(manual_entry: true)

      assert html =~ "test_media_server_connection"
    end
  end

  describe "Account mapping modal" do
    defp render_mapping(opts) do
      render_component(&Components.account_mapping_modal/1, %{
        config: Keyword.get(opts, :config, %MediaServerConfig{name: "Galactica", type: :plex}),
        state: Keyword.get(opts, :state, :ready),
        accounts: Keyword.get(opts, :accounts, []),
        users: Keyword.get(opts, :users, []),
        mapping: Keyword.get(opts, :mapping, %{}),
        saving: Keyword.get(opts, :saving, false)
      })
    end

    defp account(id, name, admin? \\ false) do
      %Mydia.MediaServer.RemoteAccount{id: id, name: name, admin?: admin?}
    end

    defp users, do: [%{id: "u-admin", username: "admin"}, %{id: "u-alex", username: "alex"}]

    defp jellyfin, do: %MediaServerConfig{name: "Jellyfin", type: :jellyfin}

    defp selected_option(html, account_id) do
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s(select[name="mapping[#{account_id}]"] option[selected]))
      |> LazyHTML.attribute("value")
      |> List.first()
    end

    test "shows a row and a user select for every account" do
      html =
        render_mapping(
          accounts: [account("1", "arsfeld", true), account("2", "Camille")],
          users: users()
        )

      assert html =~ ~s(id="account-1")
      assert html =~ ~s(id="account-2")
      assert html =~ "arsfeld"
      assert html =~ "Camille"
      assert html =~ ~s(name="mapping[1]")
      assert html =~ ~s(name="mapping[2]")
    end

    test "every select offers Don't sync plus each Mydia user" do
      html = render_mapping(accounts: [account("2", "Camille")], users: users())

      assert html =~ "Don&#39;t sync"
      assert html =~ ~s(value="u-admin")
      assert html =~ ~s(value="u-alex")
    end

    test "preselects the user the mapping names" do
      # Without this the operator's saved links would render as unmapped and a
      # blind re-save would silently unlink everyone.
      html =
        render_mapping(
          accounts: [account("1", "arsfeld"), account("2", "Camille")],
          users: users(),
          mapping: %{"1" => "u-alex", "2" => nil}
        )

      assert selected_option(html, "1") == "u-alex"
      assert selected_option(html, "2") in [nil, ""]
    end

    test "marks the Plex account owner" do
      html = render_mapping(accounts: [account("1", "arsfeld", true)], users: users())

      assert html =~ "owner"
    end

    test "reports that plex.tv is still being asked" do
      html = render_mapping(state: :loading)

      assert html =~ ~s(id="account-mapping-loading")
      assert html =~ "plex.tv"
      refute html =~ ~s(id="account-mapping-form")
    end

    test "surfaces a load failure instead of an empty list" do
      # An empty list and a failed request look identical on screen otherwise,
      # and "this account has no profiles" is the wrong thing to tell someone
      # whose token just expired.
      html = render_mapping(state: {:error, "Could not read accounts from Galactica: HTTP 401"})

      assert html =~ ~s(id="account-mapping-error")
      assert html =~ "HTTP 401"
      refute html =~ ~s(id="account-mapping-form")
    end

    test "explains an account with no Home profiles" do
      html = render_mapping(state: :ready, accounts: [])

      assert html =~ ~s(id="account-mapping-empty")
      refute html =~ ~s(id="account-mapping-form")
    end

    test "disables the save button while a save is in flight" do
      html = render_mapping(accounts: [account("2", "Camille")], users: users(), saving: true)

      assert html =~ "Saving..."

      assert html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("#account-mapping-save")
             |> LazyHTML.attribute("disabled") != []
    end

    test "a Jellyfin server is never described as having Plex profiles" do
      # The same modal renders for both providers. Plex Home copy over a list of
      # Jellyfin accounts sends the operator looking for a screen their server
      # does not have, and tells them each account has its own token when
      # Jellyfin issues none.
      html =
        render_mapping(config: jellyfin(), accounts: [account("guid-1", "Tonix")], users: users())

      assert html =~ "Jellyfin accounts"
      assert html =~ "account found"
      refute html =~ "Plex"
    end

    test "a Jellyfin load and empty state say what is actually being asked" do
      assert render_mapping(config: jellyfin(), state: :loading) =~ "this server for its accounts"

      empty = render_mapping(config: jellyfin(), state: :ready, accounts: [])
      assert empty =~ ~s(id="account-mapping-empty")
      refute empty =~ "Plex"
    end
  end
end
