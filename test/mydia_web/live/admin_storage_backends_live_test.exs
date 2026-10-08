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

    html = render_click(view, "delete_storage_backend", %{"id" => backend.id})
    assert html =~ "no longer exists"
    assert Process.alive?(view.pid)
  end

  test "test connection reports a failure message", %{conn: conn} do
    create_backend("down")

    {:ok, view, _} = live(conn, ~p"/admin/storage-backends")
    view |> element("#test-storage-backend-down") |> render_click()
    assert render_async(view, 30_000) =~ "cannot reach storage"
  end

  test "shows an info alert when there are no backends", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/admin/storage-backends")
    assert has_element?(view, "#storage-backends-empty.alert-info")
    refute has_element?(view, "#storage-backends")
  end

  test "row actions are icon-only buttons with titles", %{conn: conn} do
    create_backend("iconic")
    {:ok, view, _} = live(conn, ~p"/admin/storage-backends")

    assert has_element?(view, "#storage-backends.bg-base-200 #storage-backend-iconic")
    assert has_element?(view, "#test-storage-backend-iconic.join-item[title='Test connection']")
    assert has_element?(view, "#edit-storage-backend-iconic.join-item[title=Edit]")
    assert has_element?(view, "#delete-storage-backend-iconic.join-item.text-error[title=Delete]")
  end

  test "the modal uses the shared shell and closes from the backdrop", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/admin/storage-backends")
    view |> element("#new-storage-backend") |> render_click()

    assert has_element?(view, "#storage-backend-modal .modal-box.max-w-2xl")
    view |> element("#storage-backend-modal .modal-backdrop") |> render_click()
    refute has_element?(view, "#storage-backend-modal")
  end

  test "env-defined backends show the lock badge and disabled Edit and Delete", %{conn: conn} do
    original = Application.get_env(:mydia, :runtime_config)
    on_exit(fn -> Application.put_env(:mydia, :runtime_config, original) end)

    Application.put_env(:mydia, :runtime_config, %{
      Mydia.Config.Schema.defaults()
      | storage_backends: [
          %{
            name: "from-env",
            endpoint: "http://127.0.0.1:9",
            region: "us-east-1",
            bucket: "b",
            access_key_id: "k",
            secret_access_key: "s",
            path_style: true
          }
        ]
    })

    {:ok, view, _} = live(conn, ~p"/admin/storage-backends")

    assert has_element?(view, "#storage-backend-from-env .badge-primary .hero-lock-closed")
    assert has_element?(view, "#edit-storage-backend-from-env[disabled]")
    assert has_element?(view, "#delete-storage-backend-from-env[disabled]")
  end
end
