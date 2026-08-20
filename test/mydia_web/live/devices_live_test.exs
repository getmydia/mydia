defmodule MydiaWeb.DevicesLiveTest do
  # async: false — connected LiveView mounts do not survive the Postgres sandbox
  # when async, and these tests seed the global remote access flag.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Mydia.RemoteAccess

  setup do
    reset_remote_access()
    on_exit(&reset_remote_access/0)
    set_remote_access(true)
    :ok
  end

  defp pair_device(user, name) do
    {:ok, device} =
      RemoteAccess.create_device(%{
        device_name: name,
        platform: "android",
        token: Base.encode64(:crypto.strong_rand_bytes(32), padding: false),
        user_id: user.id
      })

    device
  end

  describe "access" do
    test "redirects an unauthenticated visitor", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/devices")
      assert path =~ "/auth"
    end

    for role <- ~w(admin user readonly guest) do
      test "renders for a #{role}", %{conn: conn} do
        user = create_test_user(%{role: unquote(role)})
        conn = log_in_user_session(conn, user)

        {:ok, view, _html} = live(conn, ~p"/devices")

        assert has_element?(view, "#devices-page")
      end
    end
  end

  describe "device list" do
    setup %{conn: conn} do
      user = create_test_user()
      %{conn: log_in_user_session(conn, user), user: user}
    end

    test "lists this user's devices", %{conn: conn, user: user} do
      device = pair_device(user, "My Phone")

      {:ok, view, _html} = live(conn, ~p"/devices")

      assert has_element?(view, "#device-#{device.id}")
    end

    test "does not list another user's devices", %{conn: conn} do
      other = create_test_user()
      other_device = pair_device(other, "Not Mine")

      {:ok, view, _html} = live(conn, ~p"/devices")

      refute has_element?(view, "#device-#{other_device.id}")
    end

    test "revokes a device", %{conn: conn, user: user} do
      device = pair_device(user, "Old Tablet")

      {:ok, view, _html} = live(conn, ~p"/devices")

      view |> element("#revoke-device-#{device.id}") |> render_click()
      view |> element("#confirm-revoke") |> render_click()

      assert RemoteAccess.get_device!(device.id).revoked_at != nil
    end

    test "deletes a device", %{conn: conn, user: user} do
      device = pair_device(user, "Dead Phone")

      {:ok, view, _html} = live(conn, ~p"/devices")

      view |> element("#delete-device-#{device.id}") |> render_click()
      view |> element("#confirm-delete") |> render_click()

      refute has_element?(view, "#device-#{device.id}")
      assert RemoteAccess.get_device(device.id) == nil
    end

    test "ignores an action for a device this user does not own", %{conn: conn} do
      other = create_test_user()
      other_device = pair_device(other, "Someone Else's")

      {:ok, view, _html} = live(conn, ~p"/devices")

      render_click(view, "open_delete_modal", %{"id" => other_device.id})

      refute has_element?(view, "#delete-modal")
      assert RemoteAccess.get_device(other_device.id) != nil
    end
  end

  describe "device liveness display" do
    setup %{conn: conn} do
      user = create_test_user()
      %{conn: log_in_user_session(conn, user), device: pair_device(user, "Liveness Device")}
    end

    defp touch(device, seconds_ago: seconds) do
      seen = DateTime.utc_now() |> DateTime.add(-seconds, :second) |> DateTime.truncate(:second)

      device
      |> Ecto.Changeset.change(last_seen_at: seen)
      |> Mydia.Repo.update!()
    end

    test "a device seen moments ago renders as online", %{conn: conn, device: device} do
      touch(device, seconds_ago: 5)

      {:ok, _view, html} = live(conn, ~p"/devices")

      assert html =~ "Online now"
    end

    test "a device that comes online after mount is picked up without a manual refresh",
         %{conn: conn, device: device} do
      touch(device, seconds_ago: 86_400)

      {:ok, view, html} = live(conn, ~p"/devices")
      refute html =~ "Online now"

      touch(device, seconds_ago: 5)
      send(view.pid, :refresh_devices)

      assert render(view) =~ "Online now"
    end
  end

  describe "pairing" do
    setup %{conn: conn} do
      user = create_test_user()
      %{conn: log_in_user_session(conn, user), user: user}
    end

    test "shows the pairing card", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/devices")

      assert has_element?(view, "#pairing-card")
    end

    test "explains itself when remote access is disabled", %{conn: conn} do
      set_remote_access(false)

      {:ok, view, html} = live(conn, ~p"/devices")

      assert has_element?(view, "#pairing-disabled-notice")
      refute has_element?(view, "#pair-device-button")
      assert html =~ "Ask an administrator"
    end

    test "explains itself when the relay is not connected", %{conn: conn} do
      # Remote access is on (setup), but no p2p server runs under MIX_ENV=test,
      # so p2p_status/0 reports running: false.
      {:ok, view, html} = live(conn, ~p"/devices")

      assert has_element?(view, "#pairing-disabled-notice")
      refute has_element?(view, "#pair-device-button")
      assert html =~ "Connecting to the relay"
    end

    test "surfaces a pairing failure rather than crashing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/devices")

      # Driven directly: the button only renders once the relay is connected,
      # which never happens in the test environment.
      html = render_click(view, "open_pairing_modal", %{})

      assert has_element?(view, "#pairing-error")
      assert html =~ "P2P service is still starting up"
      refute has_element?(view, "#claim-code")
    end

    test "reports remote access being off when generating a code", %{conn: conn} do
      set_remote_access(false)

      {:ok, view, _html} = live(conn, ~p"/devices")

      html = render_click(view, "open_pairing_modal", %{})

      assert html =~ "Remote access is turned off"
      refute has_element?(view, "#claim-code")
    end
  end

  describe "player downloads" do
    setup %{conn: conn} do
      user = create_test_user()
      %{conn: log_in_user_session(conn, user)}
    end

    test "links every platform at the download redirector", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/devices")

      assert has_element?(view, "#download-card")

      for {id, href} <- [
            {"download-android", "https://mydia.dev/download/android"},
            {"download-ios", "https://mydia.dev/download/ios"},
            {"download-macos", "https://mydia.dev/download/macos"},
            {"download-windows", "https://mydia.dev/download/windows"},
            {"download-flatpak", "https://mydia.dev/download/flatpak"},
            {"download-linux", "https://mydia.dev/download/linux"}
          ] do
        assert has_element?(view, "##{id}[href=\"#{href}\"]")
      end
    end

    test "links the web player at this instance", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/devices")

      assert has_element?(view, "#download-web[href=\"/player\"]")
    end

    test "opens external downloads in a new tab without window.opener", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/devices")

      assert has_element?(view, "#download-android[target=\"_blank\"][rel=\"noopener\"]")
    end
  end

  describe "navigation" do
    test "the sidebar links to /devices", %{conn: conn} do
      user = create_test_user()
      conn = log_in_user_session(conn, user)

      {:ok, view, _html} = live(conn, ~p"/devices")

      assert has_element?(view, "a[href=\"/devices\"]")
    end

    test "/admin/devices redirects to /devices", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_user_session(conn, admin)

      conn = get(conn, ~p"/admin/devices")

      assert redirected_to(conn) == ~p"/devices"
    end
  end
end
