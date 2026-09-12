defmodule MydiaWeb.AdminApiKeysLiveTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures

  alias Mydia.Accounts
  alias Mydia.Accounts.ApiKey
  alias Mydia.Repo

  setup %{conn: conn} do
    admin = admin_user_fixture()
    %{conn: log_in_user(conn, admin), admin: admin}
  end

  defp created_key(view) do
    view
    |> element("#created-api-key")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute("value")
    |> List.first()
  end

  test "a non-admin is sent away" do
    conn = log_in_user(build_conn(), user_fixture())
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin/config/api-keys")
  end

  test "the page has its own active tab", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/config/api-keys")
    assert has_element?(view, ~s|a[href="/admin/config/api-keys"].tab-active|)
    assert has_element?(view, "#api-keys-empty")
  end

  test "creates a Library API key and shows it exactly once", %{conn: conn, admin: admin} do
    {:ok, view, _html} = live(conn, ~p"/admin/config/api-keys")

    view |> element("#new-api-key") |> render_click()

    view
    |> form("#api-key-form", api_key: %{name: "Automation", expiry: "30", scope: "library"})
    |> render_submit()

    plain = created_key(view)
    assert "mydia_ak_" <> _ = plain
    assert has_element?(view, "#created-api-key-modal", "Treat it like your password")

    assert {:ok, user, key} = Accounts.verify_api_key(plain)
    assert user.id == admin.id
    assert key.permissions == ["admin"]
    assert DateTime.diff(key.expires_at, DateTime.utc_now(), :day) in 29..30

    view |> element("#close-created-api-key") |> render_click()

    refute has_element?(view, "#created-api-key-modal")
    refute render(view) =~ plain
    assert has_element?(view, "#api-key-#{key.id}", "Automation")
    assert has_element?(view, "#api-key-#{key.id}", "Library API")
  end

  test "a blank name is refused and nothing is created", %{conn: conn, admin: admin} do
    {:ok, view, _html} = live(conn, ~p"/admin/config/api-keys")
    view |> element("#new-api-key") |> render_click()

    view
    |> form("#api-key-form", api_key: %{name: "", expiry: "never", scope: "library"})
    |> render_submit()

    assert has_element?(view, "#api-key-form", "can't be blank")
    assert Accounts.list_api_keys(admin.id) == []
  end

  test "revokes a key after confirmation", %{conn: conn, admin: admin} do
    {:ok, key, _plain} = Accounts.create_api_key(admin.id, %{name: "Old", permissions: ["admin"]})
    {:ok, view, _html} = live(conn, ~p"/admin/config/api-keys")

    view |> element("#revoke-api-key-#{key.id}") |> render_click()
    assert has_element?(view, "#api-key-confirm-modal", "Old")

    view |> element("#confirm-api-key-action") |> render_click()

    assert Repo.get!(ApiKey, key.id).revoked_at
    assert has_element?(view, "#api-key-#{key.id}", "Revoked")
    refute has_element?(view, "#revoke-api-key-#{key.id}")
  end

  test "deletes a key after confirmation", %{conn: conn, admin: admin} do
    {:ok, key, _plain} =
      Accounts.create_api_key(admin.id, %{name: "Gone", permissions: ["admin"]})

    {:ok, view, _html} = live(conn, ~p"/admin/config/api-keys")

    view |> element("#delete-api-key-#{key.id}") |> render_click()
    view |> element("#confirm-api-key-action") |> render_click()

    refute Repo.get(ApiKey, key.id)
    refute has_element?(view, "#api-key-#{key.id}")
  end

  test "cancelling the confirmation leaves the key alone", %{conn: conn, admin: admin} do
    {:ok, key, _plain} =
      Accounts.create_api_key(admin.id, %{name: "Kept", permissions: ["admin"]})

    {:ok, view, _html} = live(conn, ~p"/admin/config/api-keys")

    view |> element("#delete-api-key-#{key.id}") |> render_click()
    view |> element("#cancel-api-key-confirm") |> render_click()

    refute has_element?(view, "#api-key-confirm-modal")
    assert Repo.get(ApiKey, key.id)
  end

  test "lists only the signed-in admin's keys", %{conn: conn} do
    other = admin_user_fixture()

    {:ok, theirs, _plain} =
      Accounts.create_api_key(other.id, %{name: "Theirs", permissions: ["admin"]})

    {:ok, view, _html} = live(conn, ~p"/admin/config/api-keys")

    refute has_element?(view, "#api-key-#{theirs.id}")
  end

  test "shows the LIBRARY_API_KEY row only while the variable is set", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/config/api-keys")
    refute has_element?(view, "#env-library-api-key")

    previous = Application.get_env(:mydia, :library_api_key)
    on_exit(fn -> Application.put_env(:mydia, :library_api_key, previous) end)
    Application.put_env(:mydia, :library_api_key, String.duplicate("k", 32))

    {:ok, view, _html} = live(conn, ~p"/admin/config/api-keys")

    assert has_element?(
             view,
             "#env-library-api-key",
             "Set by LIBRARY_API_KEY. Remove the variable and restart to revoke."
           )
  end
end
