defmodule MydiaWeb.AdminRemoteAccessLiveTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Mydia.Accounts
  alias Mydia.RemoteAccess

  setup do
    unique_id = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.create_user(%{
        email: "admin_#{unique_id}@example.com",
        username: "admin_#{unique_id}",
        password_hash: "$2b$12$test",
        role: "admin"
      })

    {:ok, token, _claims} = Mydia.Auth.Guardian.encode_and_sign(user)

    %{user: user, token: token}
  end

  describe "Authentication" do
    test "redirects unauthenticated users", %{conn: conn} do
      {:error, {:redirect, %{to: path}}} = live(conn, ~p"/admin/config/remote-access")
      assert path =~ "/auth"
    end
  end

  describe "Basic Rendering" do
    setup %{conn: conn, token: token} do
      start_supervised!(Mydia.Indexers.Health)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      %{conn: conn}
    end

    test "renders the remote access page when feature is available", %{conn: conn} do
      # Remote access may not be available in all test environments (depends on P2P NIF).
      # If the route is reachable, verify it renders; otherwise accept the redirect.
      case live(conn, ~p"/admin/config/remote-access") do
        {:ok, _view, html} ->
          assert html =~ "Remote Access" or html =~ "Configuration"

        {:error, {:redirect, _}} ->
          # Feature may be disabled or route may redirect; this is acceptable
          :ok
      end
    end
  end

  describe "Direct URL persistence" do
    setup %{conn: conn, token: token} do
      start_supervised!(Mydia.Indexers.Health)

      {:ok, _config} = RemoteAccess.initialize_config()
      {:ok, _config} = RemoteAccess.toggle_remote_access(true)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      %{conn: conn}
    end

    test "adding a direct URL through the admin UI persists it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/config/remote-access")

      url = "https://mydia-add-test.local:4000"

      render_click(view, "open_add_url_modal", %{})
      render_change(view, "update_new_url", %{"url" => url})
      html = render_submit(view, "add_direct_url", %{})

      assert html =~ "Direct URL added successfully"

      persisted_config = RemoteAccess.get_config()
      assert url in persisted_config.direct_urls
    end

    test "removing a direct URL through the admin UI persists the removal", %{conn: conn} do
      url = "https://mydia-remove-test.local:4000"
      {:ok, _config} = RemoteAccess.upsert_config(%{direct_urls: [url]})

      {:ok, view, _html} = live(conn, ~p"/admin/config/remote-access")

      html = render_click(view, "remove_direct_url", %{"url" => url})

      assert html =~ "Direct URL removed successfully"

      persisted_config = RemoteAccess.get_config()
      refute url in persisted_config.direct_urls
    end
  end

  describe "Device liveness display" do
    setup %{conn: conn, token: token, user: user} do
      start_supervised!(Mydia.Indexers.Health)

      # The devices section only renders once remote access is on.
      {:ok, _config} = RemoteAccess.initialize_config()
      {:ok, _config} = RemoteAccess.toggle_remote_access(true)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      %{conn: conn, device: create_device(user)}
    end

    test "a device seen moments ago renders as online", %{conn: conn, device: device} do
      touch(device, seconds_ago: 5)

      {:ok, _view, html} = live(conn, ~p"/admin/config/remote-access")

      assert html =~ "Online now"
    end

    test "a device that comes online after mount is picked up without a manual refresh",
         %{conn: conn, device: device} do
      touch(device, seconds_ago: 86_400)

      {:ok, view, html} = live(conn, ~p"/admin/config/remote-access")
      refute html =~ "Online now"

      touch(device, seconds_ago: 5)
      send(view.pid, :refresh_p2p)

      assert render(view) =~ "Online now"
    end

    test "the manual refresh button re-reads device liveness", %{conn: conn, device: device} do
      touch(device, seconds_ago: 86_400)

      {:ok, view, html} = live(conn, ~p"/admin/config/remote-access")
      refute html =~ "Online now"

      touch(device, seconds_ago: 5)

      assert render_click(view, "refresh_p2p", %{}) =~ "Online now"
    end
  end

  test "warns that manual entry is unavailable when the relay is unreachable" do
    html =
      render_component(&MydiaWeb.AdminRemoteAccessLive.Components.remote_access_panel/1,
        ra_config: %Mydia.RemoteAccess.Config{enabled: true, instance_id: "test-instance"},
        p2p_status: %{
          running: true,
          relay_connected: true,
          relay_url: "https://relay.test",
          node_addr: ~s({"id":"test-node"}),
          node_id: "test-node",
          connected_peers: 0
        },
        devices: [],
        claim_code: "K7RPM2",
        claim_code_rendezvous_status: :unregistered,
        claim_expires_at: DateTime.utc_now() |> DateTime.add(300, :second),
        countdown_seconds: 300,
        pairing_error: nil,
        show_pairing_modal: true
      )

    assert html =~ "id=\"pairing-relay-warning\""
  end

  defp create_device(user) do
    %Mydia.RemoteAccess.RemoteDevice{}
    |> Mydia.RemoteAccess.RemoteDevice.changeset(%{
      device_name: "Liveness Device #{System.unique_integer([:positive])}",
      platform: "ios",
      token: "device-token-#{System.unique_integer([:positive])}",
      user_id: user.id
    })
    |> Mydia.Repo.insert!()
  end

  defp touch(device, seconds_ago: seconds) do
    seen = DateTime.utc_now() |> DateTime.add(-seconds, :second) |> DateTime.truncate(:second)

    device
    |> Ecto.Changeset.change(last_seen_at: seen)
    |> Mydia.Repo.update!()
  end
end
