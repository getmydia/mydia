defmodule MydiaWeb.SessionControllerTest do
  use MydiaWeb.ConnCase

  alias Mydia.Accounts

  setup do
    # Get the current runtime config and ensure local auth is enabled
    original_config = Application.get_env(:mydia, :runtime_config)

    config =
      original_config ||
        %Mydia.Config.Schema{
          auth: %Mydia.Config.Schema.Auth{
            local_enabled: true,
            oidc_enabled: false
          }
        }

    # Ensure local auth is enabled
    config = put_in(config.auth.local_enabled, true)
    Application.put_env(:mydia, :runtime_config, config)

    on_exit(fn ->
      if original_config do
        Application.put_env(:mydia, :runtime_config, original_config)
      else
        Application.delete_env(:mydia, :runtime_config)
      end
    end)

    :ok
  end

  describe "GET /auth/login" do
    test "redirects to setup when no users exist", %{conn: conn} do
      conn = get(conn, ~p"/auth/login")
      assert redirected_to(conn) == ~p"/setup"
    end

    test "renders login form when users exist", %{conn: conn} do
      # Create a user first
      {:ok, _user} =
        Accounts.create_user(%{
          username: "testuser",
          email: "test@example.com",
          password: "password123",
          role: "user"
        })

      conn = get(conn, ~p"/auth/login")
      assert html_response(conn, 200) =~ "Sign In"
      assert html_response(conn, 200) =~ "Username"
      assert html_response(conn, 200) =~ "Password"
    end

    test "redirects when local auth is disabled", %{conn: conn} do
      # Create a user so we don't hit setup redirect
      {:ok, _user} =
        Accounts.create_user(%{
          username: "testuser",
          email: "test@example.com",
          password: "password123",
          role: "user"
        })

      # Disable local auth
      config = Application.get_env(:mydia, :runtime_config)
      config = put_in(config.auth.local_enabled, false)
      Application.put_env(:mydia, :runtime_config, config)

      conn = get(conn, ~p"/auth/login")
      assert redirected_to(conn) == "/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Local authentication is disabled"
    end
  end

  describe "POST /auth/local/login" do
    setup do
      # Create a test user with known credentials
      {:ok, user} =
        Accounts.create_user(%{
          username: "loginuser",
          email: "login@example.com",
          password: "validpassword123",
          role: "user"
        })

      %{user: user}
    end

    test "logs in user with valid credentials", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/auth/local/login", %{
          "user" => %{
            "username" => user.username,
            "password" => "validpassword123"
          }
        })

      assert redirected_to(conn) == "/"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Successfully logged in"
    end

    test "shows error with invalid password", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/auth/local/login", %{
          "user" => %{
            "username" => user.username,
            "password" => "wrongpassword"
          }
        })

      assert html_response(conn, 200) =~ "Invalid username or password"
    end

    test "shows error with non-existent username", %{conn: conn} do
      conn =
        post(conn, ~p"/auth/local/login", %{
          "user" => %{
            "username" => "nonexistent",
            "password" => "somepassword"
          }
        })

      assert html_response(conn, 200) =~ "Invalid username or password"
    end

    test "redirects when local auth is disabled", %{conn: conn, user: user} do
      # Disable local auth
      config = Application.get_env(:mydia, :runtime_config)
      config = put_in(config.auth.local_enabled, false)
      Application.put_env(:mydia, :runtime_config, config)

      conn =
        post(conn, ~p"/auth/local/login", %{
          "user" => %{
            "username" => user.username,
            "password" => "validpassword123"
          }
        })

      assert redirected_to(conn) == "/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Local authentication is disabled"
    end
  end
end
