defmodule MydiaWeb.AdminDownloadClientsLive.BuiltInSettingsTest do
  # Mutates the built-in runtime (persistent_term), the :runtime_config app env
  # on save and registers a process under BuiltIn.Manager's name.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Mydia.Config.Schema.BuiltInTorrent
  alias Mydia.Downloads.BuiltIn
  alias Mydia.Downloads.BuiltIn.{Config, Settings, Status}
  alias MydiaWeb.AdminDownloadClientsLive.BuiltInFormComponents

  @moduletag :capture_log

  # Publishes a fixed config where BuiltIn.Manager.current/0 reads it, so the page reads
  # the preflight file from a temp dir instead of /config/gluetun.
  defmodule FakeManager do
    use GenServer

    def start_link(config),
      do: GenServer.start_link(__MODULE__, config, name: Mydia.Downloads.BuiltIn.Manager)

    @impl true
    def init(config) do
      # So terminate/2 runs on the test supervisor's shutdown and the next
      # test does not read this config.
      Process.flag(:trap_exit, true)

      :persistent_term.put(
        {Mydia.Downloads.BuiltIn.Manager, Mydia.Downloads.BuiltIn.Manager},
        config
      )

      {:ok, config}
    end

    @impl true
    def terminate(_reason, _config),
      do:
        :persistent_term.erase({Mydia.Downloads.BuiltIn.Manager, Mydia.Downloads.BuiltIn.Manager})

    @impl true
    def handle_call(:current, _from, config), do: {:reply, config, config}
  end

  setup %{conn: conn} do
    unique_id = System.unique_integer([:positive])

    {:ok, user} =
      Mydia.Accounts.create_user(%{
        email: "admin_#{unique_id}@example.com",
        username: "admin_#{unique_id}",
        password_hash: "$2b$12$test",
        role: "admin"
      })

    {:ok, token, _} = Mydia.Auth.Guardian.encode_and_sign(user)

    conn =
      conn
      |> init_test_session(%{})
      |> put_session(:guardian_default_token, token)
      |> put_req_header("authorization", "Bearer #{token}")

    start_supervised!(Mydia.Indexers.Health)
    start_supervised!({Status, name: Status})

    previous = Application.get_env(:mydia, :runtime_config)

    on_exit(fn ->
      BuiltIn.clear_runtime()

      if previous,
        do: Application.put_env(:mydia, :runtime_config, previous),
        else: Application.delete_env(:mydia, :runtime_config)
    end)

    %{conn: conn}
  end

  defp run_built_in(config) do
    BuiltIn.put_runtime(%BuiltIn.Runtime{
      api_port: 3030,
      credentials: {"mydia", "x"},
      config: config
    })
  end

  defp open_settings(conn) do
    {:ok, view, _html} = live(conn, ~p"/admin/clients")
    render_click(element(view, "#built-in-configure"))
    assert has_element?(view, "#built-in-settings-modal")
    view
  end

  defp put_row(field, value) do
    {:ok, _} =
      Mydia.Settings.upsert_config_setting(%{
        key: "built_in_torrent.#{field}",
        value: value,
        category: :built_in_torrent
      })
  end

  describe "panel" do
    test "an off client still renders, with its reason and an Enable action", %{conn: conn} do
      BuiltIn.clear_runtime()
      {:ok, view, _html} = live(conn, ~p"/admin/clients")

      assert has_element?(view, "#built-in-torrent")
      assert has_element?(view, "#built-in-off-reason", "another download client is configured")
      assert has_element?(view, "#built-in-enable")
      assert has_element?(view, "#built-in-configure")
    end

    test "automatic off because rqbit is missing says so", %{conn: conn} do
      BuiltIn.clear_runtime()
      start_supervised!({FakeManager, %Config{enabled?: false, rqbit_missing?: true}})
      {:ok, view, _html} = live(conn, ~p"/admin/clients")

      assert has_element?(view, "#built-in-off-reason", "rqbit is not installed")
      refute has_element?(view, "#built-in-off-reason", "another download client")
    end

    test "a client whose tree failed to start says so", %{conn: conn} do
      BuiltIn.clear_runtime()
      config = %Config{enabled?: true, warnings: [{:start_failed, :eaddrinuse}]}
      start_supervised!({FakeManager, config})
      {:ok, view, _html} = live(conn, ~p"/admin/clients")

      assert has_element?(view, "#built-in-off-reason", "failed to start")
      assert has_element?(view, "#built-in-off-reason", "eaddrinuse")
    end

    test "a running client offers Configure and no Enable", %{conn: conn} do
      run_built_in(%Config{enabled?: true})
      {:ok, view, _html} = live(conn, ~p"/admin/clients")

      assert has_element?(view, "#built-in-configure")
      refute has_element?(view, "#built-in-enable")
      refute has_element?(view, "#built-in-off-reason")
    end
  end

  describe "settings modal" do
    test "opens on the torrent section and closes", %{conn: conn} do
      view = open_settings(conn)

      assert has_element?(view, "#built-in-settings-form")
      assert has_element?(view, "#built-in-section-torrent")
      assert has_element?(view, "#built-in-section-vpn.hidden")

      render_click(element(view, "#built-in-tab-vpn"))
      assert has_element?(view, "#built-in-section-torrent.hidden")
      refute has_element?(view, "#built-in-section-vpn.hidden")

      render_click(element(view, "#built-in-settings-modal-close"))
      refute has_element?(view, "#built-in-settings-modal")
    end

    test "a single-type provider hides the type control and shows OpenVPN fields", %{
      conn: conn
    } do
      view = open_settings(conn)

      render_change(element(view, "#built-in-settings-form"), %{
        "built_in" => %{"vpn_provider" => "mullvad"}
      })

      assert has_element?(view, "#built-in-vpn-type")

      render_change(element(view, "#built-in-settings-form"), %{
        "built_in" => %{"vpn_provider" => "private internet access"}
      })

      refute has_element?(view, "#built-in-vpn-type")
      assert has_element?(view, "#built-in-field-vpn_openvpn_user")
      assert has_element?(view, "#built-in-field-vpn_openvpn_password")
      refute has_element?(view, "#built-in-field-vpn_wireguard_addresses")
      # Private Internet Access forwards ports.
      assert has_element?(view, "#built-in-field-vpn_port_forwarding")
    end

    test "gluetun's pia alias shows the Private Internet Access fields", %{conn: conn} do
      view = open_settings(conn)

      render_change(element(view, "#built-in-settings-form"), %{
        "built_in" => %{"vpn_provider" => "pia"}
      })

      assert has_element?(view, "#built-in-field-vpn_openvpn_user")
      assert has_element?(view, "#built-in-field-vpn_openvpn_password")
      assert has_element?(view, "#built-in-field-vpn_port_forwarding")

      assert has_element?(
               view,
               ~s(#built-in-field-vpn_provider option[value="private internet access"][selected])
             )
    end

    test "choosing WireGuard on the type control swaps the credential fields", %{conn: conn} do
      view = open_settings(conn)

      render_change(element(view, "#built-in-settings-form"), %{
        "built_in" => %{"vpn_provider" => "mullvad"}
      })

      render_click(element(view, "#built-in-vpn-type-wireguard"))

      assert has_element?(view, "#built-in-field-vpn_wireguard_addresses")
      assert has_element?(view, "#built-in-field-vpn_wireguard_private_key")
      refute has_element?(view, "#built-in-field-vpn_openvpn_user")
    end

    test "a provider needing extra variables names them", %{conn: conn} do
      view = open_settings(conn)

      render_change(element(view, "#built-in-settings-form"), %{
        "built_in" => %{"vpn_provider" => "vpn unlimited"}
      })

      assert has_element?(view, "#built-in-vpn-extra-env", "MYDIA_VPN_OPENVPN_CERT")
      assert has_element?(view, "#built-in-vpn-extra-env", "MYDIA_VPN_OPENVPN_KEY")
    end

    test "a saved password is never rendered and offers Replace", %{conn: conn} do
      put_row(:vpn_openvpn_password, "hunter2-secret-value")
      view = open_settings(conn)

      render_change(element(view, "#built-in-settings-form"), %{
        "built_in" => %{"vpn_provider" => "private internet access"}
      })

      assert has_element?(view, "#built-in-secret-replace-vpn_openvpn_password")
      refute has_element?(view, "#built-in-field-vpn_openvpn_password")
      refute render(view) =~ "hunter2-secret-value"

      render_click(element(view, "#built-in-secret-replace-vpn_openvpn_password"))
      assert has_element?(view, "#built-in-field-vpn_openvpn_password[value='']")
      refute render(view) =~ "hunter2-secret-value"
    end

    test "a typed secret is not echoed back after validation", %{conn: conn} do
      view = open_settings(conn)

      render_change(element(view, "#built-in-settings-form"), %{
        "built_in" => %{
          "vpn_provider" => "private internet access",
          "vpn_openvpn_password" => "typed-secret-xyz"
        }
      })

      refute render(view) =~ "typed-secret-xyz"
    end

    test "turning the client off with active downloads asks first", %{conn: conn} do
      run_built_in(%Config{enabled?: true})
      insert(:download, download_client: BuiltIn.name())
      view = open_settings(conn)

      render_submit(element(view, "#built-in-settings-form"), %{
        "built_in" => %{"enabled" => "false"}
      })

      assert has_element?(view, "#built-in-confirm-disable", "1 download")
      assert has_element?(view, "#built-in-settings-modal")
      assert Mydia.Settings.get_config_setting_by_key("built_in_torrent.enabled") == nil

      render_submit(element(view, "#built-in-settings-form"), %{
        "built_in" => %{"enabled" => "false"}
      })

      refute has_element?(view, "#built-in-settings-modal")

      assert %{value: "false"} =
               Mydia.Settings.get_config_setting_by_key("built_in_torrent.enabled")
    end

    test "switching to automatic when that resolves off asks like off", %{conn: conn} do
      # Another torrent client is configured, so automatic resolves off.
      create_test_download_client()
      run_built_in(%Config{enabled?: true})
      insert(:download, download_client: BuiltIn.name())
      view = open_settings(conn)

      render_submit(element(view, "#built-in-settings-form"), %{
        "built_in" => %{"enabled" => "automatic"}
      })

      assert has_element?(view, "#built-in-confirm-disable", "1 download")
      assert has_element?(view, "#built-in-settings-modal")
    end

    test "the download path explains what a change affects; Cancel has an id", %{conn: conn} do
      view = open_settings(conn)

      assert has_element?(
               view,
               "#built-in-section-torrent",
               "Torrents already in the session finish in their original folder"
             )

      render_click(element(view, "#built-in-settings-cancel"))
      refute has_element?(view, "#built-in-settings-modal")
    end

    test "a secret's label points at an input only when one is shown", %{conn: conn} do
      put_row(:vpn_openvpn_password, "hunter2-secret-value")
      view = open_settings(conn)

      render_change(element(view, "#built-in-settings-form"), %{
        "built_in" => %{"vpn_provider" => "private internet access"}
      })

      refute has_element?(view, "label[for='built-in-field-vpn_openvpn_password']")

      render_click(element(view, "#built-in-secret-replace-vpn_openvpn_password"))
      assert has_element?(view, "label[for='built-in-field-vpn_openvpn_password']")
    end

    test "turning the VPN off while the engine runs asks first", %{conn: conn} do
      run_built_in(%Config{enabled?: true, vpn?: true, vpn_provider: "mullvad"})
      view = open_settings(conn)

      render_submit(element(view, "#built-in-settings-form"), %{
        "built_in" => %{"vpn_enabled" => "false"}
      })

      assert has_element?(view, "#built-in-confirm-vpn-off")
      refute has_element?(view, "#built-in-confirm-disable")
      assert has_element?(view, "#built-in-settings-modal")
    end

    # The dev shell sets MYDIA_TORRENT_PORT and the paths, which locks those
    # fields, so these tests use VPN fields no environment sets.
    test "a save closes the modal and flashes", %{conn: conn} do
      view = open_settings(conn)

      render_submit(element(view, "#built-in-settings-form"), %{
        "built_in" => %{"vpn_server_countries" => "Atlantis"}
      })

      refute has_element?(view, "#built-in-settings-modal")
      assert render(view) =~ "Built-in torrent client settings saved"

      assert %{value: "Atlantis"} =
               Mydia.Settings.get_config_setting_by_key("built_in_torrent.vpn_server_countries")
    end

    test "switching to a provider without port forwarding clears it on save", %{conn: conn} do
      put_row("vpn_provider", "protonvpn")
      put_row("vpn_port_forwarding", "true")
      {:ok, _} = Mydia.Config.Loader.reload()

      view = open_settings(conn)
      assert has_element?(view, "#built-in-field-vpn_port_forwarding[checked]")

      render_change(element(view, "#built-in-settings-form"), %{
        "built_in" => %{"vpn_provider" => "mullvad"}
      })

      refute has_element?(view, "#built-in-field-vpn_port_forwarding")

      render_submit(element(view, "#built-in-settings-form"), %{
        "built_in" => %{"vpn_provider" => "mullvad"}
      })

      refute has_element?(view, "#built-in-settings-modal")
      assert Mydia.Settings.get_runtime_config().built_in_torrent.vpn_port_forwarding == false
    end

    test "an invalid save keeps the modal open with the error", %{conn: conn} do
      view = open_settings(conn)

      render_submit(element(view, "#built-in-settings-form"), %{
        "built_in" => %{"vpn_provider" => "not-a-provider", "vpn_server_countries" => "Atlantis"}
      })

      assert has_element?(view, "#built-in-settings-modal")
      assert render(view) =~ "is not a supported provider"
      # The error is in the VPN section, which is shown.
      refute has_element?(view, "#built-in-section-vpn.hidden")

      assert Mydia.Settings.get_config_setting_by_key("built_in_torrent.vpn_server_countries") ==
               nil
    end

    @tag :tmp_dir
    test "missing capabilities show the setup card and lock the VPN toggle", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      File.write!(Path.join(tmp_dir, "preflight"), "net_admin=missing\ntun=ok\n")
      start_supervised!({FakeManager, %Config{enabled?: true, gluetun_dir: tmp_dir}})
      view = open_settings(conn)

      card = element(view, "#built-in-vpn-setup-card")
      assert render(card) =~ "NET_ADMIN"
      assert render(card) =~ "/dev/net/tun"
      assert render(card) =~ "net.ipv4.conf.all.src_valid_mark=1"
      assert has_element?(view, "#built-in-field-vpn_enabled[disabled]")
    end

    @tag :tmp_dir
    test "with capabilities missing and the VPN on, the toggle stays enabled to turn it off", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      File.write!(Path.join(tmp_dir, "preflight"), "net_admin=missing\ntun=ok\n")

      start_supervised!(
        {FakeManager,
         %Config{enabled?: true, vpn?: true, vpn_provider: "mullvad", gluetun_dir: tmp_dir}}
      )

      put_row(:vpn_enabled, "true")
      put_row(:vpn_provider, "mullvad")
      {:ok, _} = Mydia.Config.Loader.reload()
      run_built_in(%Config{enabled?: true, vpn?: true, vpn_provider: "mullvad"})
      view = open_settings(conn)

      assert has_element?(view, "#built-in-vpn-setup-card")
      assert has_element?(view, "#built-in-field-vpn_enabled")
      refute has_element?(view, "#built-in-field-vpn_enabled[disabled]")

      form = element(view, "#built-in-settings-form")
      render_submit(form, %{"built_in" => %{"vpn_enabled" => "false"}})
      assert has_element?(view, "#built-in-confirm-vpn-off")

      render_submit(form, %{"built_in" => %{"vpn_enabled" => "false"}})
      refute has_element?(view, "#built-in-settings-modal")

      assert %{value: "false"} =
               Mydia.Settings.get_config_setting_by_key("built_in_torrent.vpn_enabled")
    end

    test "the state path field explains that a new path starts a new session", %{conn: conn} do
      view = open_settings(conn)
      assert has_element?(view, "#built-in-hint-state_path")
    end

    @tag :tmp_dir
    test "a missing src_valid_mark alone shows the card but leaves the toggle", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      File.write!(Path.join(tmp_dir, "preflight"), "src_valid_mark=missing\n")
      start_supervised!({FakeManager, %Config{enabled?: true, gluetun_dir: tmp_dir}})
      view = open_settings(conn)

      assert has_element?(view, "#built-in-vpn-setup-card")
      refute has_element?(view, "#built-in-field-vpn_enabled[disabled]")
    end
  end

  describe "enable" do
    test "Enable saves enabled = true", %{conn: conn} do
      BuiltIn.clear_runtime()
      {:ok, view, _html} = live(conn, ~p"/admin/clients")

      render_click(element(view, "#built-in-enable"))

      assert %{value: "true"} =
               Mydia.Settings.get_config_setting_by_key("built_in_torrent.enabled")
    end
  end

  describe "built_in_settings_modal/1" do
    defp modal_assigns(overrides) do
      form =
        %{}
        |> Settings.form_changeset(%BuiltInTorrent{}, getenv: fn _ -> nil end)
        |> Phoenix.Component.to_form(as: :built_in)

      Map.merge(
        %{
          form: form,
          section: :torrent,
          sources: %{},
          saved_secrets: %{},
          replacing: [],
          typed_secrets: [],
          confirm: nil,
          preflight: :absent,
          env_vpn_names: []
        },
        overrides
      )
    end

    test "an env-sourced field is disabled with an ENV badge" do
      html =
        render_component(
          &BuiltInFormComponents.built_in_settings_modal/1,
          modal_assigns(%{sources: %{download_path: :env}})
        )

      doc = LazyHTML.from_fragment(html)
      assert LazyHTML.query(doc, "#built-in-field-download_path[disabled]") |> Enum.count() == 1

      badge = LazyHTML.query(doc, "#built-in-source-download_path") |> LazyHTML.text()
      assert badge =~ "ENV"
      assert html =~ "MYDIA_TORRENT_DOWNLOAD_PATH"

      assert LazyHTML.query(doc, "#built-in-field-listen_port[disabled]") |> Enum.count() == 0
    end

    test "lists environment-only VPN variable names, never values" do
      html =
        render_component(
          &BuiltInFormComponents.built_in_settings_modal/1,
          modal_assigns(%{env_vpn_names: ["MYDIA_VPN_SERVER_NAMES"]})
        )

      list =
        html |> LazyHTML.from_fragment() |> LazyHTML.query("#built-in-env-vpn-names")

      assert Enum.count(list) == 1
      assert LazyHTML.text(list) =~ "MYDIA_VPN_SERVER_NAMES"
      refute LazyHTML.text(list) =~ "="
    end
  end
end
