defmodule MydiaWeb.AdminPathMappingsLive.IndexTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Mydia.{Accounts, Downloads, Settings}
  alias Mydia.Config.Loader

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

  defp authed(conn, token) do
    conn
    |> init_test_session(%{})
    |> put_session(:guardian_default_token, token)
    |> put_req_header("authorization", "Bearer #{token}")
  end

  describe "redirects" do
    test "unauthenticated users are redirected", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/admin/path-mappings")
      assert path =~ "/auth"
    end
  end

  describe "CRUD" do
    setup %{conn: conn, token: token} do
      {:ok, view, _html} = live(authed(conn, token), ~p"/admin/path-mappings")
      {:ok, view: view}
    end

    test "shows the empty state when no mappings exist", %{view: view} do
      assert has_element?(view, "#path-mappings-empty")
    end

    test "creates a mapping via the modal", %{view: view} do
      view |> element("button", "Add mapping") |> render_click()

      view
      |> form("#path-mapping-form", %{
        path_mapping_config: %{
          remote_prefix: "/downloads/complete",
          local_prefix: "/data/torrents/complete"
        }
      })
      |> render_submit()

      assert has_element?(view, "#path-mappings-list")
      assert render(view) =~ "/downloads/complete"
      assert [mapping] = Settings.list_path_mapping_configs()
      assert mapping.local_prefix == "/data/torrents/complete"
    end

    test "shows a validation error for a blank local prefix", %{view: view} do
      view |> element("button", "Add mapping") |> render_click()

      html =
        view
        |> form("#path-mapping-form", %{
          path_mapping_config: %{remote_prefix: "/downloads/complete", local_prefix: ""}
        })
        |> render_submit()

      assert html =~ "can&#39;t be blank" or html =~ "can't be blank"
      assert Settings.list_path_mapping_configs() == []
    end

    test "remote_prefix autocomplete suggests failed-import reported paths", %{view: view} do
      {:ok, _download} =
        Downloads.create_download(%{
          title: "Some Release",
          import_failed_at: DateTime.utc_now() |> DateTime.truncate(:second),
          import_failure_reason: "path_mapping_mismatch",
          import_reported_path: "/remote/seedbox/complete"
        })

      view |> element("button", "Add mapping") |> render_click()

      assert has_element?(
               view,
               "datalist#remote-prefix-suggestions option[value='/remote/seedbox/complete']"
             )
    end

    test "deletes a DB mapping", %{conn: conn, token: token} do
      {:ok, mapping} =
        Settings.create_path_mapping_config(%{
          remote_prefix: "/downloads/complete",
          local_prefix: "/data/torrents/complete"
        })

      {:ok, view, _html} = live(authed(conn, token), ~p"/admin/path-mappings")

      view
      |> element("#mapping-#{mapping.id} button[phx-click='delete_path_mapping']")
      |> render_click()

      assert Settings.list_path_mapping_configs() == []
    end
  end

  describe "env-sourced mappings are read-only" do
    setup %{conn: conn, token: token} do
      System.put_env("PATH_MAPPING_1_REMOTE", "/downloads/env")
      System.put_env("PATH_MAPPING_1_LOCAL", "/data/env")
      {:ok, _} = Loader.reload(config_file: "nonexistent.yml")

      on_exit(fn ->
        System.delete_env("PATH_MAPPING_1_REMOTE")
        System.delete_env("PATH_MAPPING_1_LOCAL")
        Loader.reload(config_file: "nonexistent.yml")
      end)

      {:ok, view, _html} = live(authed(conn, token), ~p"/admin/path-mappings")
      {:ok, view: view}
    end

    test "renders the ENV badge and disables edit/delete", %{view: view} do
      assert render(view) =~ "ENV"
      assert has_element?(view, "button[phx-click='edit_path_mapping'][disabled]")
      assert has_element?(view, "button[phx-click='delete_path_mapping'][disabled]")
    end
  end
end
