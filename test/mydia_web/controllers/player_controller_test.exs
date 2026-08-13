defmodule MydiaWeb.PlayerControllerTest do
  use MydiaWeb.ConnCase

  alias Mydia.Auth.Guardian

  describe "index/2" do
    test "redirects to login when not authenticated", %{conn: conn} do
      conn = get(conn, ~p"/player")
      assert redirected_to(conn) == ~p"/auth/login"
    end

    test "when logged in via SessionController flow, player shows authenticated", %{conn: conn} do
      # This test mimics the real login flow through SessionController
      # to verify Guardian.Plug.sign_in properly stores the token

      # Create test user
      user = create_test_user()

      # Create temp player index.html
      player_dir = Path.join([:code.priv_dir(:mydia), "static", "player"])
      File.mkdir_p!(player_dir)
      index_path = Path.join(player_dir, "index.html")

      index_content = """
      <!DOCTYPE html>
      <html>
      <head><title>Test</title></head>
      <body>
        <script src="flutter_bootstrap.js" async></script>
      </body>
      </html>
      """

      File.write!(index_path, index_content)
      on_exit(fn -> File.rm(index_path) end)

      # Simulate what SessionController.create does:
      # 1. Create a token
      # 2. Call Guardian.Plug.sign_in (which should store in session)
      # 3. Also store in :guardian_token (legacy)
      {:ok, token, _claims} = Guardian.create_token(user)

      conn =
        conn
        |> init_test_session(%{})
        |> Guardian.Plug.sign_in(user)
        |> put_session(:guardian_token, token)

      # Now make request to /player - should be authenticated
      conn = get(conn, ~p"/player")

      html_response = response(conn, 200)
      assert html_response =~ "window.mydiaConfig"

      assert html_response =~ "\"authenticated\":true",
             "Expected authenticated:true but got: #{html_response}"
    end

    test "end-to-end: login via POST then access player", %{conn: conn} do
      # Create test user with known password
      user = create_test_user(%{password: "testpassword123"})

      # Create temp player index.html
      player_dir = Path.join([:code.priv_dir(:mydia), "static", "player"])
      File.mkdir_p!(player_dir)
      index_path = Path.join(player_dir, "index.html")

      index_content = """
      <!DOCTYPE html>
      <html>
      <head><title>Test</title></head>
      <body>
        <script src="flutter_bootstrap.js" async></script>
      </body>
      </html>
      """

      File.write!(index_path, index_content)
      on_exit(fn -> File.rm(index_path) end)

      # Initialize session and POST to login
      conn = conn |> init_test_session(%{})

      # Login via the actual SessionController endpoint
      login_conn =
        post(conn, ~p"/auth/local/login", %{
          "user" => %{
            "username" => user.username,
            "password" => "testpassword123"
          }
        })

      # Verify login succeeded (redirects to /)
      assert redirected_to(login_conn) == "/"

      # Now use the same session to access /player
      # We need to recycle the conn to preserve session
      player_conn = recycle(login_conn)

      player_response = get(player_conn, ~p"/player")
      html = response(player_response, 200)

      assert html =~ "window.mydiaConfig"

      assert html =~ "\"authenticated\":true",
             "Expected authenticated:true in response. Check if session is properly preserved."
    end

    test "when authenticated, injects mydiaConfig with auth data into HTML", %{conn: conn} do
      # Create temp player index.html for the test
      player_dir = Path.join([:code.priv_dir(:mydia), "static", "player"])
      File.mkdir_p!(player_dir)

      index_path = Path.join(player_dir, "index.html")

      index_content = """
      <!DOCTYPE html>
      <html>
      <head><title>Test</title></head>
      <body>
        <script src="flutter_bootstrap.js" async></script>
      </body>
      </html>
      """

      File.write!(index_path, index_content)

      on_exit(fn ->
        File.rm(index_path)
      end)

      {conn, user} = register_and_log_in_user(conn)
      conn = get(conn, ~p"/player")

      html_response = response(conn, 200)
      assert html_response =~ "window.mydiaConfig"
      assert html_response =~ "\"authenticated\":true"
      # userId is encoded as JSON string
      assert html_response =~ "\"userId\":\"#{user.id}\""
      assert html_response =~ "\"username\":\"#{user.username}\""
      # Should have a token
      assert html_response =~ "\"token\":\""
    end

    test "when authenticated, handles player not built gracefully", %{conn: conn} do
      # Ensure player index doesn't exist
      player_index = Path.join([:code.priv_dir(:mydia), "static", "player", "index.html"])
      exists_before = File.exists?(player_index)

      if exists_before do
        backup = File.read!(player_index)
        File.rm!(player_index)

        on_exit(fn ->
          File.write!(player_index, backup)
        end)
      end

      {conn, _user} = register_and_log_in_user(conn)
      conn = get(conn, ~p"/player")

      assert response(conn, 404)
    end
  end

  describe "player bundle caching" do
    setup do
      player_dir = Path.join([:code.priv_dir(:mydia), "static", "player"])
      File.mkdir_p!(player_dir)
      bundle = Path.join(player_dir, "main.dart.js")

      # In a dev checkout this is a real Flutter build that costs a full
      # `flutter build web` to replace, so put back whatever was here.
      previous = File.read(bundle)

      File.write!(bundle, "console.log('bundle');")
      # Dated, so the etag memo is exercised rather than bypassed by the
      # settle window the way a just-written file would be.
      File.touch!(bundle, System.os_time(:second) - 3600)

      on_exit(fn ->
        case previous do
          {:ok, content} -> File.write!(bundle, content)
          {:error, _} -> File.rm(bundle)
        end
      end)

      {:ok, bundle: bundle}
    end

    test "the bundle must be revalidated rather than reused on heuristic freshness",
         %{conn: conn} do
      # Flutter reuses the same URL for every build, so a cached copy that a
      # browser may serve without asking is a client pinned to whichever build
      # it happened to fetch. "public" alone permits exactly that.
      conn = get(conn, "/player/main.dart.js")

      assert response(conn, 200)
      assert get_resp_header(conn, "cache-control") == ["no-cache"]
    end

    test "an unchanged bundle still revalidates to a bodiless 304", %{conn: conn} do
      etag = fetch_etag()

      conn =
        conn
        |> put_req_header("if-none-match", etag)
        |> get("/player/main.dart.js")

      assert response(conn, 304) == ""
    end

    test "a redeploy that only restamps mtimes does not re-send the bundle",
         %{conn: conn, bundle: bundle} do
      etag = fetch_etag()

      # A container image gives every file it ships a fresh mtime, so the
      # default phash2({size, mtime}) validator would miss here and push the
      # whole bundle again to prove nothing changed.
      File.touch!(bundle, System.os_time(:second) - 60)

      conn =
        conn
        |> put_req_header("if-none-match", etag)
        |> get("/player/main.dart.js")

      assert response(conn, 304) == ""
    end

    test "a build whose clock ran ahead of this host is still cacheable",
         %{conn: conn, bundle: bundle} do
      etag = fetch_etag()

      File.touch!(bundle, System.os_time(:second) + 3600)

      conn =
        conn
        |> put_req_header("if-none-match", etag)
        |> get("/player/main.dart.js")

      assert response(conn, 304) == ""
    end

    test "a genuinely new build does re-send", %{conn: conn, bundle: bundle} do
      etag = fetch_etag()

      File.write!(bundle, "console.log('next build');")
      File.touch!(bundle, System.os_time(:second) - 60)

      conn =
        conn
        |> put_req_header("if-none-match", etag)
        |> get("/player/main.dart.js")

      assert response(conn, 200) =~ "next build"
    end

    test "a deep link still falls through to the player shell", %{conn: conn} do
      # The new static mount sits in front of the router's "/player/*path"
      # glob. A miss must pass through rather than 404, or every Flutter
      # route stops resolving on a cold load.
      {conn, _user} = register_and_log_in_user(conn)

      index = Path.join([:code.priv_dir(:mydia), "static", "player", "index.html"])
      File.mkdir_p!(Path.dirname(index))
      previous = File.read(index)

      File.write!(
        index,
        "<html><body><script src=\"flutter_bootstrap.js\"></script></body></html>"
      )

      on_exit(fn ->
        case previous do
          {:ok, content} -> File.write!(index, content)
          {:error, _} -> File.rm(index)
        end
      end)

      assert conn |> get("/player/movies/123") |> response(200) =~ "flutter_bootstrap.js"
    end

    defp fetch_etag do
      etag =
        build_conn()
        |> get("/player/main.dart.js")
        |> get_resp_header("etag")
        |> List.first()

      assert etag
      etag
    end
  end
end
