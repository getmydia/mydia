defmodule MydiaWeb.Plugs.ScopeAssignmentTest do
  use MydiaWeb.ConnCase, async: false

  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Accounts.Scope
  alias Mydia.RemoteAccess.{MediaToken, RemoteDevice}

  test "an authenticated browser request carries a Scope struct", %{conn: conn} do
    user = restricted_user_fixture(%{allowed_categories: ["cartoon_movie"]})

    conn =
      conn
      |> log_in_user(user)
      |> get(~p"/movies")

    assert %Scope{} = conn.assigns.current_scope
    assert conn.assigns.current_scope.allowed_categories == ["cartoon_movie"]
  end

  test "an authenticated API request carries a Scope struct", %{conn: conn} do
    user = restricted_user_fixture(%{max_content_age: 7})

    conn =
      conn
      |> log_in_user(user)
      |> get(~p"/api/v1/indexers")

    assert %Scope{max_content_age: 7} = conn.assigns.current_scope
  end

  test "an admin request carries an unrestricted scope", %{conn: conn} do
    conn =
      conn
      |> log_in_user(admin_user_fixture())
      |> get(~p"/movies")

    refute Scope.restricted?(conn.assigns.current_scope)
  end

  test "an API-key request carries a Scope struct", %{conn: conn} do
    user = restricted_user_fixture(%{max_content_age: 7})
    {:ok, _record, plain_key} = Mydia.Accounts.create_api_key(user.id, %{name: "Scope Key"})

    # ApiAuth rate-limits API keys per client IP in a global ETS table, and
    # other tests (some async) spend failed attempts from 127.0.0.1. A
    # dedicated address keeps this request out of their bucket, so it is never
    # answered 429 before a scope is assigned.
    conn =
      %{conn | remote_ip: {10, 91, 0, 42}}
      |> put_req_header("x-api-key", plain_key)
      |> get(~p"/api/v1/indexers")

    assert %Scope{max_content_age: 7} = conn.assigns.current_scope
  end

  test "a media-token request carries a Scope struct", %{conn: conn} do
    # A media token is only honoured while remote access is on, and that flag
    # lives in :persistent_term.
    reset_remote_access()
    on_exit(&reset_remote_access/0)
    set_remote_access(true)

    user = restricted_user_fixture(%{max_content_age: 7})

    device =
      %RemoteDevice{}
      |> RemoteDevice.changeset(%{
        device_name: "Scope Device",
        platform: "ios",
        token: "device-token-#{System.unique_integer([:positive])}",
        user_id: user.id
      })
      |> Mydia.Repo.insert!()

    {:ok, token, _claims} = MediaToken.create_token(device)
    movie = media_item_fixture(%{title: "Scope Token Movie"})

    conn = get(conn, "/api/v1/stream/movie/#{movie.id}?token=#{token}")

    assert %Scope{max_content_age: 7} = conn.assigns.current_scope
  end
end
