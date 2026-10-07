defmodule MydiaWeb.AdminStorageBackendsLiveTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Mydia.Accounts
  alias Mydia.Settings

  setup %{conn: conn} do
    unique_id = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.create_user(%{
        email: "admin_#{unique_id}@example.com",
        username: "admin_#{unique_id}",
        password_hash: "$2b$12$test",
        role: "admin"
      })

    {:ok, token, _claims} = Mydia.Auth.Guardian.encode_and_sign(user)

    conn =
      conn
      |> init_test_session(%{})
      |> put_session(:guardian_default_token, token)
      |> put_req_header("authorization", "Bearer #{token}")

    %{conn: conn}
  end

  defp create_backend(name, secret \\ "s") do
    {:ok, backend} =
      Settings.create_storage_backend(%{
        name: name,
        endpoint: "http://127.0.0.1:9",
        bucket: "b",
        access_key_id: "k",
        secret_access_key: secret
      })

    backend
  end

  test "redirects unauthenticated users" do
    {:error, {:redirect, %{to: path}}} = live(build_conn(), ~p"/admin/storage-backends")
    assert path =~ "/auth"
  end

  test "creates a backend and never renders the secret", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/storage-backends")

    view |> element("#new-storage-backend") |> render_click()

    view
    |> form("#storage-backend-form",
      storage_backend: %{
        name: "media",
        endpoint: "http://127.0.0.1:9",
        region: "us-east-1",
        bucket: "b",
        access_key_id: "AKID",
        secret_access_key: "very-secret",
        path_style: "true"
      }
    )
    |> render_submit()

    assert has_element?(view, "#storage-backend-media")
    refute render(view) =~ "very-secret"
  end

  test "edit modal does not render the stored secret and blank keeps it", %{conn: conn} do
    backend = create_backend("keepme", "stored-secret-123")
    {:ok, view, _} = live(conn, ~p"/admin/storage-backends")

    html = view |> element("#edit-storage-backend-keepme") |> render_click()
    refute html =~ "stored-secret-123"
    assert has_element?(view, "#storage-backend-form")

    view
    |> form("#storage-backend-form",
      storage_backend: %{bucket: "other", secret_access_key: ""}
    )
    |> render_submit()

    updated = Settings.get_storage_backend!(backend.id)
    assert updated.bucket == "other"
    assert updated.secret_access_key == "stored-secret-123"
  end

  test "deletes a backend", %{conn: conn} do
    create_backend("gone")
    {:ok, view, _} = live(conn, ~p"/admin/storage-backends")

    view |> element("#delete-storage-backend-gone") |> render_click()
    refute has_element?(view, "#storage-backend-gone")
  end

  test "refuses to delete a backend a library still uses", %{conn: conn} do
    create_backend("inuse")

    {:ok, _} =
      Settings.create_library_path(%{path: "s3://inuse/movies", type: :movies, monitored: true})

    {:ok, view, _} = live(conn, ~p"/admin/storage-backends")

    html = view |> element("#delete-storage-backend-inuse") |> render_click()
    assert html =~ "Cannot delete storage backend inuse"
    assert has_element?(view, "#storage-backend-inuse")
  end

  test "a backend already deleted by someone else does not crash the page", %{conn: conn} do
    backend = create_backend("raced")
    {:ok, view, _} = live(conn, ~p"/admin/storage-backends")
    Mydia.Repo.delete!(backend)

    html = render_click(view, "delete", %{"id" => backend.id})
    assert html =~ "no longer exists"
    assert Process.alive?(view.pid)
  end

  test "test connection reports a failure message", %{conn: conn} do
    create_backend("down")

    {:ok, view, _} = live(conn, ~p"/admin/storage-backends")
    view |> element("#test-storage-backend-down") |> render_click()
    assert render_async(view, 30_000) =~ "cannot reach storage"
  end
end
