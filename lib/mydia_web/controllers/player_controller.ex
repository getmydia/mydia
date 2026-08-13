defmodule MydiaWeb.PlayerController do
  use MydiaWeb, :controller

  alias Mydia.Auth.Guardian

  require Logger

  @moduledoc """
  Serves the Flutter web player application.

  This controller handles the main /player route and serves the Flutter
  web app's index.html, allowing Flutter's hash-based routing to work.

  For authenticated users, the controller injects auth configuration
  into the HTML so the Flutter app can auto-authenticate without
  requiring manual login.

  Serves from priv/static/player/ in all environments. In development,
  the FlutterWatcher GenServer automatically rebuilds the player when
  files change.
  """

  @doc """
  Serves the Flutter web player's index.html.

  The Flutter app uses hash-based routing (e.g., /player/#/movies/123),
  so all routes should serve the same index.html and let Flutter handle
  the routing on the client side.

  For authenticated users, injects:
  - Auth token (JWT)
  - User info (id, username)
  - Server URL is auto-detected by Flutter from window.location.origin
  """
  def index(conn, _params) do
    case fetch_player_html(conn) do
      {:ok, html_content} ->
        # Get auth info from session
        auth_config = build_auth_config(conn)

        # Inject auth config before the Flutter bootstrap
        modified_html = inject_auth_config(html_content, auth_config)

        conn
        |> put_resp_content_type("text/html")
        # This document is per-user and carries a Guardian JWT in
        # `window.mydiaConfig`, so it must not be written to any cache. It is
        # also the only thing pointing at the asset URLs, which is the other
        # reason it can never be served from one: a stale shell would reinstate
        # exactly the pinned-old-client problem the static mount below fixes.
        |> put_resp_header("cache-control", "no-store")
        |> send_resp(200, modified_html)

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> put_view(html: MydiaWeb.ErrorHTML)
        |> render(:"404")

      {:error, reason} ->
        Logger.error("Failed to fetch player HTML: #{inspect(reason)}")

        conn
        |> put_status(:service_unavailable)
        |> put_view(html: MydiaWeb.ErrorHTML)
        |> render(:"500")
    end
  end

  # Always serve from static files (same in dev and prod)
  # In development, FlutterWatcher rebuilds automatically on file changes
  defp fetch_player_html(_conn) do
    player_index_path = Path.join([:code.priv_dir(:mydia), "static", "player", "index.html"])

    if File.exists?(player_index_path) do
      {:ok, File.read!(player_index_path)}
    else
      {:error, :not_found}
    end
  end

  # Build the auth configuration to inject into the page
  defp build_auth_config(conn) do
    case Guardian.Plug.current_resource(conn) do
      nil ->
        # No authenticated user
        %{authenticated: false, embedMode: true}

      user ->
        # Get the token from session (check both Guardian default key and legacy key)
        token =
          get_session(conn, :guardian_default_token) ||
            get_session(conn, :guardian_token) ||
            create_fresh_token(user)

        %{
          authenticated: true,
          token: token,
          userId: user.id,
          username: user.username,
          embedMode: true
        }
    end
  end

  # Create a fresh token if one doesn't exist in the session
  defp create_fresh_token(user) do
    case Guardian.create_token(user) do
      {:ok, token, _claims} -> token
      _ -> nil
    end
  end

  # Inject auth config as a JavaScript global before the Flutter bootstrap
  defp inject_auth_config(html_content, auth_config) do
    config_json = Jason.encode!(auth_config)

    auth_script = """
    <script>
      // Mydia auth configuration injected by Phoenix
      // Flutter web app reads this to auto-authenticate
      window.mydiaConfig = #{config_json};

      // Capture the initial URL hash before Flutter loads
      // This is needed because Flutter's dart:html window.location may not have
      // the hash available by the time the router initializes
      window.mydiaInitialHash = window.location.hash || '';
      console.log('[Phoenix] Captured initial hash:', window.mydiaInitialHash);
      console.log('[Phoenix] Full href:', window.location.href);
    </script>
    """

    # Insert the auth script just before the flutter_bootstrap.js script
    String.replace(
      html_content,
      ~r/<script src="flutter_bootstrap\.js"/,
      auth_script <> "\n  <script src=\"flutter_bootstrap.js\""
    )
  end
end
