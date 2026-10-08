defmodule MydiaWeb.AdminMediaServersLive.ComponentsTest do
  use ExUnit.Case, async: true

  # Only `render_component/2` is needed here, and importing `render/1` alongside
  # the local helpers below is noise. Matches franchise_components_test.exs.
  import Phoenix.LiveViewTest, except: [render: 1]
  import Phoenix.Component, only: [to_form: 1]

  alias Mydia.Accounts.User
  alias Mydia.Settings.MediaServerConfig
  alias MydiaWeb.AdminMediaServersLive.AccountMappingComponents
  alias MydiaWeb.AdminMediaServersLive.Components
  alias MydiaWeb.AdminMediaServersLive.MediaServerModalComponents

  defp render_modal(opts) do
    config = Keyword.get(opts, :config, %MediaServerConfig{type: :jellyfin})

    render_component(&MediaServerModalComponents.media_server_modal/1, %{
      media_server_form: to_form(MediaServerConfig.changeset(config, %{})),
      media_server_mode: Keyword.get(opts, :mode, :new)
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

  defp server(attrs \\ %{}) do
    struct!(
      %MediaServerConfig{
        id: "11111111-1111-1111-1111-111111111111",
        name: "Storage",
        type: :jellyfin,
        enabled: true,
        url: "http://localhost:8096",
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

    test "an env-configured server keeps edit and delete visible but disabled" do
      s = runtime_server()

      doc =
        [s]
        |> render_tab(%{s.id => %{status: :unknown}})
        |> LazyHTML.from_fragment()

      assert LazyHTML.query(doc, "button[disabled][title=Edit]") |> Enum.count() == 1
      assert LazyHTML.query(doc, "button[disabled][title=Delete]") |> Enum.count() == 1
    end

    test "a normal server offers edit and delete and carries no env note" do
      s = server()

      html = render_tab([s], %{s.id => %{status: :unknown}})

      assert html =~ "edit_media_server"
      assert html =~ "delete_media_server"
      refute html =~ ~s(data-test="env-config-note")
    end
  end

  describe "media server modal, Jellyfin-only form" do
    test "the URL is required" do
      html = render_modal(config: %MediaServerConfig{type: :jellyfin})

      assert url_input_required?(html)
      assert html =~ "default: 8096"
    end

    test "the type is fixed to Jellyfin by a hidden input, with no type select" do
      html = render_modal([])

      document = LazyHTML.from_fragment(html)

      assert LazyHTML.attribute(
               LazyHTML.query(
                 document,
                 ~s(input[type="hidden"][name="media_server_config[type]"])
               ),
               "value"
             ) == ["jellyfin"]

      assert Enum.empty?(LazyHTML.query(document, ~s(select[name="media_server_config[type]"])))
    end

    test "no Plex wizard is rendered" do
      html = render_modal([])

      refute html =~ "phx-hook"
      refute html =~ "Sign in with Plex"
      refute html =~ "plex-discovery-summary"
    end

    test "Add Server and Test Connection are both offered" do
      html = render_modal(mode: :new)

      assert html =~ "test_media_server_connection"

      disabled =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#media-server-submit")
        |> LazyHTML.attribute("disabled")

      assert disabled == []
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

  describe "Account mapping modal" do
    defp render_mapping(opts) do
      render_component(&AccountMappingComponents.account_mapping_modal/1, %{
        config: Keyword.get(opts, :config, jellyfin()),
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

    defp users do
      [
        %User{id: "u-admin", username: "admin"},
        %User{id: "u-alex", username: "alex"}
      ]
    end

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

    test "marks the account owner" do
      html = render_mapping(accounts: [account("1", "arsfeld", true)], users: users())

      assert html =~ "owner"
    end

    test "reports that the server is still being asked" do
      html = render_mapping(state: :loading)

      assert html =~ ~s(id="account-mapping-loading")
      assert html =~ "this server for its accounts"
      refute html =~ ~s(id="account-mapping-form")
    end

    test "surfaces a load failure instead of an empty list" do
      # An empty list and a failed request look identical on screen otherwise,
      # and "this server has no accounts" is the wrong thing to tell someone
      # whose token just expired.
      html = render_mapping(state: {:error, "Could not read accounts from Galactica: HTTP 401"})

      assert html =~ ~s(id="account-mapping-error")
      assert html =~ "HTTP 401"
      refute html =~ ~s(id="account-mapping-form")
    end

    test "explains a server with no accounts" do
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

    test "a Jellyfin server is described as having accounts, never Plex profiles" do
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

    test "labels an SSO account by its display name rather than a blank option" do
      # An OIDC-provisioned account has no username, so the option used to
      # render with an empty label and the operator could not tell which
      # account they were picking.
      sso = %User{id: "u-sso", username: nil, display_name: "Robin Vega", email: "r@example.test"}

      html = render_mapping(accounts: [account("1", "Camille")], users: users() ++ [sso])

      assert html =~ "Robin Vega"
      assert html =~ ~s(value="u-sso")
    end
  end
end
