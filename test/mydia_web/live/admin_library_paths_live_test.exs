defmodule MydiaWeb.AdminLibraryPathsLiveTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Mydia.Accounts

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

  describe "Authentication" do
    test "redirects unauthenticated users", %{conn: conn} do
      {:error, {:redirect, %{to: path}}} = live(conn, ~p"/admin/config/library-paths")
      assert path =~ "/auth"
    end
  end

  describe "Library Paths" do
    setup %{conn: conn, token: token} do
      start_supervised!(Mydia.Indexers.Health)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      {:ok, view, _html} = live(conn, ~p"/admin/config/library-paths")
      %{conn: conn, view: view}
    end

    test "displays empty state when no paths exist", %{conn: conn, token: token} do
      Mydia.Settings.list_library_paths()
      |> Enum.each(fn library_path ->
        unless is_binary(library_path.id) and String.starts_with?(library_path.id, "runtime::") do
          Mydia.Settings.delete_library_path(library_path)
        end
      end)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      {:ok, _view, html} = live(conn, ~p"/admin/config/library-paths")
      assert html =~ "Library Paths"
    end

    test "creates a new library path", %{view: view} do
      test_dir =
        Path.join(System.tmp_dir!(), "test_library_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(test_dir)

      on_exit(fn ->
        File.rm_rf(test_dir)
      end)

      view
      |> element(~s{button[phx-click="new_library_path"]})
      |> render_click()

      view
      |> form("#library-path-form",
        library_path: %{
          path: test_dir,
          type: "movies",
          monitored: "true"
        }
      )
      |> render_submit()

      Process.sleep(100)

      html = render(view)
      assert html =~ test_dir
      refute has_element?(view, ~s{div[class*="modal-open"]})
    end

    test "shows TV metadata source select for series libraries and persists it", %{view: view} do
      test_dir =
        Path.join(System.tmp_dir!(), "test_series_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(test_dir)
      on_exit(fn -> File.rm_rf(test_dir) end)

      view
      |> element(~s{button[phx-click="new_library_path"]})
      |> render_click()

      # Type defaults to nil; switching to series reveals the gated select.
      html =
        view
        |> form("#library-path-form", library_path: %{type: "series"})
        |> render_change()

      assert html =~ "TV Metadata Source"

      view
      |> form("#library-path-form",
        library_path: %{
          path: test_dir,
          type: "series",
          monitored: "true",
          tv_metadata_source: "tmdb"
        }
      )
      |> render_submit()

      Process.sleep(100)

      library_path = Enum.find(Mydia.Settings.list_library_paths(), &(&1.path == test_dir))
      assert library_path.tv_metadata_source == :tmdb
    end

    test "hides TV metadata source select for movie libraries", %{view: view} do
      view
      |> element(~s{button[phx-click="new_library_path"]})
      |> render_click()

      html =
        view
        |> form("#library-path-form", library_path: %{type: "movies"})
        |> render_change()

      refute html =~ "TV Metadata Source"
    end

    test "shows a metadata source badge on every library, aligned across types", %{
      conn: conn,
      token: token
    } do
      {:ok, tmdb_series} =
        Mydia.Settings.create_library_path(%{
          path: "/tmp/series_#{System.unique_integer([:positive])}",
          type: "series",
          tv_metadata_source: "tmdb"
        })

      {:ok, tvdb_series} =
        Mydia.Settings.create_library_path(%{
          path: "/tmp/series_#{System.unique_integer([:positive])}",
          type: "series",
          tv_metadata_source: "tvdb"
        })

      {:ok, movie} =
        Mydia.Settings.create_library_path(%{
          path: "/tmp/movies_#{System.unique_integer([:positive])}",
          type: "movies"
        })

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      {:ok, view, _html} = live(conn, ~p"/admin/config/library-paths")

      # Every library shows a source badge (scoped per row), so the badge column
      # stays aligned across types: movies always source from TMDB, series use
      # their configured provider.
      assert has_element?(
               view,
               ~s{#library-path-#{movie.id} [data-tip="Metadata source"]},
               "TMDB"
             )

      assert has_element?(
               view,
               ~s{#library-path-#{tmdb_series.id} [data-tip="Metadata source"]},
               "TMDB"
             )

      assert has_element?(
               view,
               ~s{#library-path-#{tvdb_series.id} [data-tip="Metadata source"]},
               "TVDB"
             )

      on_exit(fn ->
        Enum.each([tmdb_series, tvdb_series, movie], &Mydia.Settings.delete_library_path/1)
      end)
    end
  end

  describe "Automatic scanning" do
    setup %{conn: conn, token: token} do
      start_supervised!(Mydia.Indexers.Health)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      {:ok, view, _html} = live(conn, ~p"/admin/config/library-paths")
      %{conn: conn, view: view}
    end

    test "the form exposes an automatic scanning control", %{view: view} do
      open_new_form(view)

      assert has_element?(view, ~s{select[name="library_path[scan_interval]"]})
    end

    test "choosing an interval persists it", %{view: view} do
      dir = tmp_library_dir()

      open_new_form(view)

      view
      |> form("#library-path-form",
        library_path: %{
          path: dir,
          type: "movies",
          monitored: "true",
          scan_interval: "3600"
        }
      )
      |> render_submit()

      Process.sleep(100)

      assert saved_path(dir).scan_interval == 3600
    end

    test "the Off option saves a nil interval, meaning manual only", %{view: view} do
      dir = tmp_library_dir()

      open_new_form(view)

      view
      |> form("#library-path-form",
        library_path: %{
          path: dir,
          type: "movies",
          monitored: "true",
          scan_interval: ""
        }
      )
      |> render_submit()

      Process.sleep(100)

      assert saved_path(dir).scan_interval == nil
    end
  end

  defp open_new_form(view) do
    view |> element(~s{button[phx-click="new_library_path"]}) |> render_click()
  end

  defp tmp_library_dir do
    dir = Path.join(System.tmp_dir!(), "scan_interval_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp saved_path(dir) do
    Enum.find(Mydia.Settings.list_library_paths(), &(&1.path == dir))
  end
end
