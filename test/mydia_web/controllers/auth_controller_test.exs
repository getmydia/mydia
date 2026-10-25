defmodule MydiaWeb.AuthControllerTest do
  use MydiaWeb.ConnCase

  alias Mydia.Auth.Guardian

  describe "GET /auth/logout" do
    test "ends the session: guardian_default_token cleared, current_resource nil afterwards", %{
      conn: conn
    } do
      user = create_test_user(%{password: "testpassword123"})

      conn = init_test_session(conn, %{})

      # Log in through the real controller flow (not a test shortcut), so the
      # session ends up in exactly the shape a browser session would.
      login_conn =
        post(conn, ~p"/auth/local/login", %{
          "user" => %{"username" => user.username, "password" => "testpassword123"}
        })

      assert redirected_to(login_conn) == "/"

      # Prove the session actually authenticates before logout, so a later
      # failure demonstrates logout revoked it rather than the login never
      # having worked in the first place.
      authed_conn = login_conn |> recycle() |> get(~p"/")
      assert %Mydia.Accounts.User{} = Guardian.Plug.current_resource(authed_conn)

      logout_conn = login_conn |> recycle() |> get(~p"/auth/logout")

      # This is the crux of T-010: router.ex previously declared the dynamic
      # "/:provider" route before the literal "/logout" route in the same
      # scope, so GET /auth/logout dispatched to AuthController.request/2
      # instead of AuthController.logout/2. request/2 also redirects to
      # "/auth/login" when OIDC isn't configured (the default), so a
      # same-path-only assertion would pass even under the bug. The
      # assertions below check that the session was actually torn down, not
      # just that the response landed on a login-shaped URL.
      assert redirected_to(logout_conn) == "/"
      assert get_session(logout_conn, :guardian_default_token) == nil
      assert get_session(logout_conn, :guardian_token) == nil
      assert Guardian.Plug.current_resource(logout_conn) == nil

      # And the session is unusable for a follow-up request, exactly as a
      # browser would make one after clicking "Logout".
      after_logout_conn = logout_conn |> recycle() |> get(~p"/")
      assert redirected_to(after_logout_conn) == ~p"/auth/login"
    end
  end
end

defmodule MydiaWeb.AuthControllerLinkTest do
  use MydiaWeb.ConnCase, async: false

  alias Mydia.Accounts
  alias Mydia.Auth.Guardian

  setup do
    original = Application.get_env(:ueberauth, Ueberauth)

    # Any non-empty provider list makes oidc_configured?/0 true. The provider
    # is deliberately not named :oidc: RuntimeUeberauth would otherwise claim
    # /auth/oidc/callback and run the real strategy against no IdP, so these
    # tests could not hand the controller a prepared Ueberauth.Auth.
    Application.put_env(:ueberauth, Ueberauth,
      providers: [test_only: {Ueberauth.Strategy.Oidcc, []}]
    )

    runtime = Application.get_env(:mydia, :runtime_config)

    on_exit(fn ->
      if original,
        do: Application.put_env(:ueberauth, Ueberauth, original),
        else: Application.delete_env(:ueberauth, Ueberauth)

      if runtime,
        do: Application.put_env(:mydia, :runtime_config, runtime),
        else: Application.delete_env(:mydia, :runtime_config)
    end)

    :ok
  end

  defp put_auth(fields) do
    config = Mydia.Config.get()
    Application.put_env(:mydia, :runtime_config, %{config | auth: struct(config.auth, fields)})
  end

  # Shaped like UeberauthOidcc's own extra/1: the ID token's claims always,
  # the userinfo response only when the strategy fetched one.
  defp id_token_auth(sub, email, verified) do
    %Ueberauth.Auth{
      uid: sub,
      provider: :oidc,
      info: %Ueberauth.Auth.Info{email: email, name: "Fictional Person"},
      extra: %Ueberauth.Auth.Extra{
        raw_info: %UeberauthOidcc.RawInfo{
          opts: %{},
          claims: %{"sub" => sub, "email" => email, "email_verified" => verified},
          userinfo: nil
        }
      }
    }
  end

  defp auth(sub, email, verified \\ true) do
    %Ueberauth.Auth{
      uid: sub,
      provider: :oidc,
      info: %Ueberauth.Auth.Info{email: email, name: "Fictional Person"},
      extra: %Ueberauth.Auth.Extra{
        raw_info: %UeberauthOidcc.RawInfo{
          claims: %{"sub" => sub},
          userinfo: %{"email_verified" => verified}
        }
      }
    }
  end

  defp callback(conn, auth) do
    conn |> assign(:ueberauth_auth, auth) |> get(~p"/auth/oidc/callback")
  end

  describe "POST /auth/oidc/link" do
    test "stores a link intent and redirects to the provider", %{conn: conn} do
      user = create_test_user()
      conn = conn |> log_in_user(user) |> post(~p"/auth/oidc/link")

      assert redirected_to(conn) == "/auth/oidc"
      assert %{"user_id" => id} = get_session(conn, :oidc_link_intent)
      assert id == user.id
    end

    test "refuses an already linked account", %{conn: conn} do
      {:ok, user} = Accounts.link_oidc_identity(create_test_user(), "sub-1", "oidc")
      conn = conn |> log_in_user(user) |> post(~p"/auth/oidc/link")

      assert redirected_to(conn) == "/profile"
      refute get_session(conn, :oidc_link_intent)
    end

    test "refuses when OIDC is not configured", %{conn: conn} do
      Application.delete_env(:ueberauth, Ueberauth)
      conn = conn |> log_in_user(create_test_user()) |> post(~p"/auth/oidc/link")

      assert redirected_to(conn) == "/profile"
      refute get_session(conn, :oidc_link_intent)
    end

    test "requires authentication", %{conn: conn} do
      conn = post(conn, ~p"/auth/oidc/link")
      assert redirected_to(conn) =~ "/auth/login"
    end

    # A GET would let a cross-site <img> start a link. Phoenix.ConnTest skips
    # CSRF by default, so turn the check back on for this request.
    test "is refused without a CSRF token", %{conn: conn} do
      user = create_test_user()

      conn =
        conn
        |> log_in_user(user)
        |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)

      assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
        post(conn, ~p"/auth/oidc/link")
      end
    end

    test "GET does not start a link", %{conn: conn} do
      conn = conn |> log_in_user(create_test_user()) |> get(~p"/auth/oidc/link")

      assert conn.status == 404
      refute get_session(conn, :oidc_link_intent)
    end
  end

  describe "callback with a link intent" do
    test "links the signed-in user and keeps the session", %{conn: conn} do
      user = create_test_user()
      conn = conn |> log_in_user(user) |> post(~p"/auth/oidc/link")
      conn = conn |> recycle() |> callback(auth("sub-1", "idp@example.test"))

      assert redirected_to(conn) == "/profile"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "linked"
      assert Accounts.get_user_by_oidc("sub-1", "oidc").id == user.id
      refute get_session(conn, :oidc_link_intent)
      assert get_session(conn, :guardian_default_token)
    end

    test "refuses an identity already on another account", %{conn: conn} do
      {:ok, _} = Accounts.link_oidc_identity(create_test_user(), "sub-1", "oidc")
      user = create_test_user()
      conn = conn |> log_in_user(user) |> post(~p"/auth/oidc/link")
      conn = conn |> recycle() |> callback(auth("sub-1", "idp@example.test"))

      assert redirected_to(conn) == "/profile"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "another"
      assert Accounts.get_user!(user.id).oidc_sub == nil
    end

    test "refuses an expired intent", %{conn: conn} do
      user = create_test_user()
      stale = System.system_time(:second) - 601

      conn =
        conn
        |> log_in_user(user)
        |> put_session(:oidc_link_intent, %{"user_id" => user.id, "issued_at" => stale})
        |> callback(auth("sub-1", "idp@example.test"))

      assert redirected_to(conn) == "/profile"
      assert Accounts.get_user!(user.id).oidc_sub == nil
      refute get_session(conn, :oidc_link_intent)
    end

    test "refuses an intent for a different signed-in user", %{conn: conn} do
      owner = create_test_user()
      other = create_test_user()

      conn =
        conn
        |> log_in_user(other)
        |> put_session(:oidc_link_intent, %{
          "user_id" => owner.id,
          "issued_at" => System.system_time(:second)
        })
        |> callback(auth("sub-1", "idp@example.test"))

      assert redirected_to(conn) == "/profile"
      assert Accounts.get_user!(owner.id).oidc_sub == nil
      assert Accounts.get_user!(other.id).oidc_sub == nil
    end

    test "refuses an intent with no signed-in session", %{conn: conn} do
      owner = create_test_user()

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:oidc_link_intent, %{
          "user_id" => owner.id,
          "issued_at" => System.system_time(:second)
        })
        |> callback(auth("sub-1", "idp@example.test"))

      assert redirected_to(conn) == "/profile"
      assert Accounts.get_user!(owner.id).oidc_sub == nil
    end

    test "a malformed intent is refused, not crashed on", %{conn: conn} do
      user = create_test_user()

      conn =
        conn
        |> log_in_user(user)
        |> put_session(:oidc_link_intent, %{"user_id" => user.id, "issued_at" => "soon"})
        |> callback(auth("sub-1", "idp@example.test"))

      assert redirected_to(conn) == "/profile"
      assert Accounts.get_user!(user.id).oidc_sub == nil
    end

    test "an IdP failure drops the intent and returns to the profile", %{conn: conn} do
      user = create_test_user()

      conn =
        conn
        |> log_in_user(user)
        |> put_session(:oidc_link_intent, %{
          "user_id" => user.id,
          "issued_at" => System.system_time(:second)
        })
        |> assign(:ueberauth_failure, %Ueberauth.Failure{
          errors: [%Ueberauth.Failure.Error{message: "denied"}]
        })
        |> get(~p"/auth/oidc/callback")

      assert redirected_to(conn) == "/profile"
      refute get_session(conn, :oidc_link_intent)
    end
  end

  describe "callback without a link intent" do
    test "an email collision explains how to link", %{conn: conn} do
      create_test_user(%{email: "pat@example.test"})

      conn =
        conn
        |> init_test_session(%{})
        |> callback(auth("sub-1", "pat@example.test", false))

      assert redirected_to(conn) == "/auth/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "link SSO from your profile"
    end

    test "a new identity signs in as before", %{conn: conn} do
      create_test_user()

      conn =
        conn
        |> init_test_session(%{})
        |> callback(auth("sub-new", "fresh@example.test"))

      assert redirected_to(conn) == "/"
      assert Accounts.get_user_by_oidc("sub-new", "oidc")
    end
  end

  describe "callback auto-linking by email" do
    setup do
      put_auth(oidc_link_by_email: true)
      local = create_test_user(%{email: "rowan@example.test", role: "readonly"})
      %{local: local}
    end

    test "a verified email signs in as the local account and links it", %{
      conn: conn,
      local: local
    } do
      conn =
        conn
        |> init_test_session(%{})
        |> callback(id_token_auth("sub-auto", "Rowan@example.test", true))

      assert redirected_to(conn) == "/"
      assert Accounts.get_user_by_oidc("sub-auto", "oidc").id == local.id

      {:ok, claims} = Guardian.decode_and_verify(get_session(conn, :guardian_default_token))
      assert claims["sub"] == local.id
      assert Accounts.get_user!(local.id).role == "readonly"
    end

    test "the string \"true\" is not a verified email", %{conn: conn, local: local} do
      conn =
        conn
        |> init_test_session(%{})
        |> callback(id_token_auth("sub-auto", "rowan@example.test", "true"))

      assert redirected_to(conn) == "/auth/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "link SSO from your profile"
      assert Accounts.get_user_by_oidc("sub-auto", "oidc") == nil
      assert Accounts.get_user!(local.id).oidc_sub == nil
      refute get_session(conn, :guardian_default_token)
    end
  end

  # Neither ueberauth_auth nor ueberauth_failure: the callback route was hit
  # without the strategy having run, so there is nothing to sign in with.
  describe "callback with no Ueberauth result" do
    test "drops a link intent and returns to the profile", %{conn: conn} do
      user = create_test_user()

      conn =
        conn
        |> log_in_user(user)
        |> put_session(:oidc_link_intent, %{
          "user_id" => user.id,
          "issued_at" => System.system_time(:second)
        })
        |> get(~p"/auth/oidc/callback")

      assert redirected_to(conn) == "/profile"
      assert Phoenix.Flash.get(conn.assigns.flash, :error)
      refute get_session(conn, :oidc_link_intent)
      assert Accounts.get_user!(user.id).oidc_sub == nil
    end

    test "without an intent returns to the login page", %{conn: conn} do
      conn = conn |> init_test_session(%{}) |> get(~p"/auth/oidc/callback")

      assert redirected_to(conn) == "/auth/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error)
    end
  end

  describe "DELETE /auth/oidc/link" do
    test "requires authentication", %{conn: conn} do
      conn = delete(conn, ~p"/auth/oidc/link")
      assert redirected_to(conn) =~ "/auth/login"
    end

    test "unlinks an account with a password", %{conn: conn} do
      {:ok, user} = Accounts.link_oidc_identity(create_test_user(), "sub-1", "oidc")
      conn = conn |> log_in_user(user) |> delete(~p"/auth/oidc/link")

      assert redirected_to(conn) == "/profile"
      assert Phoenix.Flash.get(conn.assigns.flash, :info)
      assert Accounts.get_user!(user.id).oidc_sub == nil
    end

    test "refuses an SSO-only account", %{conn: conn} do
      user = Mydia.AccountsFixtures.oidc_user_fixture()
      conn = conn |> log_in_user(user) |> delete(~p"/auth/oidc/link")

      assert redirected_to(conn) == "/profile"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "managed by your SSO provider"
      assert Accounts.get_user!(user.id).oidc_sub
    end

    test "refuses while local sign-in is disabled", %{conn: conn} do
      {:ok, user} = Accounts.link_oidc_identity(create_test_user(), "sub-1", "oidc")
      put_auth(local_enabled: false)
      conn = conn |> log_in_user(user) |> delete(~p"/auth/oidc/link")

      assert redirected_to(conn) == "/profile"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Local sign-in is disabled"
      assert Accounts.get_user!(user.id).oidc_sub
    end
  end
end
