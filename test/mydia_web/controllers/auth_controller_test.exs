defmodule MydiaWeb.AuthControllerTest do
  @moduledoc """
  Tests for the AuthController.

  Note: Some OIDC callback tests use direct controller invocation because
  the Ueberauth plug runs before the controller and requires OIDC to be
  configured at the application level. We test the controller logic directly
  by calling the controller functions with pre-assigned ueberauth data.
  """
  use MydiaWeb.ConnCase

  alias Mydia.Accounts
  alias Mydia.Auth.Guardian
  alias MydiaWeb.AuthController

  # Helper to prepare conn for direct controller calls
  defp prepare_conn(conn) do
    conn
    |> init_test_session(%{})
    |> fetch_flash()
  end

  describe "logout/2" do
    test "logs out user and clears session", %{conn: conn} do
      # Create a user
      {:ok, user} =
        Accounts.create_user(%{
          username: "logoutuser",
          email: "logout@example.com",
          password: "password123",
          role: "user"
        })

      # Create a token and put it in session
      {:ok, token, _claims} = Guardian.encode_and_sign(user, %{}, token_type: :access)

      conn =
        conn
        |> prepare_conn()
        |> put_session(:guardian_token, token)
        |> Guardian.Plug.sign_in(user)

      # Call logout directly to avoid Ueberauth plug
      conn = AuthController.logout(conn, %{})

      assert redirected_to(conn) == "/"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "logged out"
    end

    test "logout without session still redirects", %{conn: conn} do
      conn = prepare_conn(conn)

      # Call logout directly
      conn = AuthController.logout(conn, %{})

      assert redirected_to(conn) == "/"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "logged out"
    end
  end

  describe "auto_login/2" do
    setup do
      {:ok, user} =
        Accounts.create_user(%{
          username: "autologinuser",
          email: "autologin@example.com",
          password: "password123",
          role: "admin"
        })

      %{user: user}
    end

    test "auto-login with valid token signs in user", %{conn: conn, user: user} do
      {:ok, token, _claims} = Guardian.encode_and_sign(user, %{}, token_type: :access)

      conn = prepare_conn(conn)
      conn = AuthController.auto_login(conn, %{"token" => token})

      assert redirected_to(conn) == "/"
    end

    test "auto-login with invalid token shows error", %{conn: conn} do
      conn = prepare_conn(conn)
      conn = AuthController.auto_login(conn, %{"token" => "invalid_token"})

      assert redirected_to(conn) == "/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Invalid or expired"
    end
  end

  describe "request/2 (OIDC request)" do
    test "redirects to login when OIDC is not configured", %{conn: conn} do
      # Ensure no OIDC providers are configured
      original = Application.get_env(:ueberauth, Ueberauth)
      Application.put_env(:ueberauth, Ueberauth, providers: [])

      on_exit(fn ->
        if original do
          Application.put_env(:ueberauth, Ueberauth, original)
        else
          Application.delete_env(:ueberauth, Ueberauth)
        end
      end)

      conn = prepare_conn(conn)
      conn = AuthController.request(conn, %{"provider" => "oidc"})

      assert redirected_to(conn) == "/auth/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not configured"
    end
  end

  describe "callback/2 (OIDC callback)" do
    test "handles ueberauth failure", %{conn: conn} do
      failure = %Ueberauth.Failure{
        provider: :oidc,
        strategy: Ueberauth.Strategy.OIDC,
        errors: [%Ueberauth.Failure.Error{message: "Auth failed", message_key: "auth_failed"}]
      }

      conn =
        conn
        |> prepare_conn()
        |> assign(:ueberauth_failure, failure)

      conn = AuthController.callback(conn, %{})

      assert redirected_to(conn) == "/auth/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Auth failed"
    end

    test "handles successful OIDC authentication", %{conn: conn} do
      auth = %Ueberauth.Auth{
        uid: "oidc-user-123",
        provider: :oidc,
        info: %Ueberauth.Auth.Info{
          email: "oidcuser@example.com",
          name: "OIDC User",
          image: nil
        },
        extra: %Ueberauth.Auth.Extra{
          raw_info: %{
            userinfo: %{"roles" => [], "groups" => []}
          }
        }
      }

      conn =
        conn
        |> prepare_conn()
        |> assign(:ueberauth_auth, auth)

      conn = AuthController.callback(conn, %{})

      assert redirected_to(conn) == "/"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Successfully authenticated"
    end

    test "handles successful OIDC auth with admin role", %{conn: conn} do
      auth = %Ueberauth.Auth{
        uid: "oidc-admin-456",
        provider: :oidc,
        info: %Ueberauth.Auth.Info{
          email: "admin@example.com",
          name: "Admin User",
          image: nil
        },
        extra: %Ueberauth.Auth.Extra{
          raw_info: %{
            userinfo: %{"roles" => ["admin"], "groups" => []}
          }
        }
      }

      conn =
        conn
        |> prepare_conn()
        |> assign(:ueberauth_auth, auth)

      conn = AuthController.callback(conn, %{})

      assert redirected_to(conn) == "/"

      # Verify the user was created with admin role
      user = Accounts.get_user_by_oidc("oidc-admin-456", "oidc")
      assert user.role == "admin"
    end

    test "handles OIDC auth with groups for admin role", %{conn: conn} do
      auth = %Ueberauth.Auth{
        uid: "oidc-group-admin-789",
        provider: :oidc,
        info: %Ueberauth.Auth.Info{
          email: "groupadmin@example.com",
          name: "Group Admin",
          image: nil
        },
        extra: %Ueberauth.Auth.Extra{
          raw_info: %{
            userinfo: %{"roles" => [], "groups" => ["administrators"]}
          }
        }
      }

      conn =
        conn
        |> prepare_conn()
        |> assign(:ueberauth_auth, auth)

      conn = AuthController.callback(conn, %{})

      assert redirected_to(conn) == "/"

      user = Accounts.get_user_by_oidc("oidc-group-admin-789", "oidc")
      assert user.role == "admin"
    end
  end
end
