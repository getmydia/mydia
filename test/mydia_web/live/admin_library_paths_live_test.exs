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
      {:error, {:redirect, %{to: path}}} = live(conn, ~p"/admin/library-paths")
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

      {:ok, view, _html} = live(conn, ~p"/admin/library-paths")
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

      {:ok, _view, html} = live(conn, ~p"/admin/library-paths")
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

    test "keeps the write toggles enabled for s3:// paths", %{view: view} do
      view |> element(~s{button[phx-click="new_library_path"]}) |> render_click()

      refute has_element?(view, "#library-path-form input[type=checkbox][disabled]")

      view
      |> form("#library-path-form", library_path: %{path: "s3://media/movies", type: "movies"})
      |> render_change()

      for field <- ~w(auto_organize auto_rename write_nfo) do
        assert has_element?(
                 view,
                 ~s{#library-path-form input[type=checkbox][name="library_path[#{field}]"]}
               )
      end

      refute has_element?(view, "#library-path-form input[type=checkbox][disabled]")
      refute has_element?(view, "#library-path-s3-note")
    end

    test "an s3:// path on an unreachable backend is rejected by the storage check", %{
      view: view
    } do
      name = "dead#{System.unique_integer([:positive])}"

      {:ok, _} =
        Mydia.Settings.create_storage_backend(%{
          name: name,
          endpoint: "http://localhost:1",
          region: "us-east-1",
          bucket: "lib",
          access_key_id: "k",
          secret_access_key: "s",
          path_style: true
        })

      view |> element(~s{button[phx-click="new_library_path"]}) |> render_click()

      html =
        view
        |> form("#library-path-form",
          library_path: %{path: "s3://#{name}/movies", type: "movies", monitored: "true"}
        )
        |> render_submit()

      assert html =~ "Invalid directory"
      refute html =~ "directory does not exist"
      assert has_element?(view, "#library-path-form")
    end

    @tag :s3
    test "an s3:// path on a reachable backend saves", %{view: view} do
      backend = Mydia.S3Helpers.ensure_backend_row!()
      path = "s3://#{backend.name}/t-#{System.unique_integer([:positive])}"

      view |> element(~s{button[phx-click="new_library_path"]}) |> render_click()

      view
      |> form("#library-path-form",
        library_path: %{path: path, type: "movies", monitored: "true"}
      )
      |> render_submit()

      assert Enum.any?(Mydia.Settings.list_library_paths(), &(&1.path == path))
      refute has_element?(view, ~s{div[class*="modal-open"]})
    end

    test "saves a display name and shows it on the card", %{view: view} do
      test_dir =
        Path.join(System.tmp_dir!(), "test_named_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(test_dir)
      on_exit(fn -> File.rm_rf(test_dir) end)

      view
      |> element(~s{button[phx-click="new_library_path"]})
      |> render_click()

      view
      |> form("#library-path-form",
        library_path: %{path: test_dir, type: "movies", monitored: "true", name: "Kids Movies"}
      )
      |> render_submit()

      Process.sleep(100)

      library_path = Enum.find(Mydia.Settings.list_library_paths(), &(&1.path == test_dir))
      assert library_path.name == "Kids Movies"
      assert has_element?(view, "#library-path-#{library_path.id}-name", "Kids Movies")
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

      {:ok, view, _html} = live(conn, ~p"/admin/library-paths")

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

    test "offers JSON and CSV library export links", %{view: view} do
      assert has_element?(
               view,
               ~s|#library-export-json[href="/api/v1/library/export?format=json"]|
             )

      assert has_element?(view, ~s|#library-export-csv[href="/api/v1/library/export?format=csv"]|)
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

      {:ok, view, _html} = live(conn, ~p"/admin/library-paths")
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

    test "the editor is the shared modal with Monitored in the header", %{view: view} do
      open_new_form(view)

      assert has_element?(view, "#library-path-modal .modal-box.max-w-2xl .w-10.h-10.rounded-xl")

      assert has_element?(
               view,
               ~s(#library-path-modal input[type=checkbox][form="library-path-form"])
             )
    end
  end

  describe "runtime library paths" do
    @runtime_path "/media/env-films"
    @runtime_id "runtime::library_path::/media/env-films"

    setup %{conn: conn, token: token} do
      start_supervised!(Mydia.Indexers.Health)

      original = Application.get_env(:mydia, :runtime_config)

      on_exit(fn ->
        if original,
          do: Application.put_env(:mydia, :runtime_config, original),
          else: Application.delete_env(:mydia, :runtime_config)
      end)

      base = Mydia.Config.Schema.defaults()

      Application.put_env(:mydia, :runtime_config, %{
        base
        | library_paths: [%{path: @runtime_path, type: :movies}]
      })

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      {:ok, view, _html} = live(conn, ~p"/admin/library-paths")
      %{view: view}
    end

    test "a runtime library path is locked", %{view: view} do
      row = "[id='library-path-#{@runtime_id}']"

      assert has_element?(view, "#{row} .badge-primary", "ENV")
      assert has_element?(view, "#{row} button[title=Edit][disabled]")
      assert has_element?(view, "#{row} button[title=Delete][disabled]")
    end

    test "edit and delete refuse a runtime library path on the server", %{view: view} do
      render_click(view, "edit_library_path", %{"id" => @runtime_id})
      refute has_element?(view, "#library-path-modal")

      html = render_click(view, "delete_library_path", %{"id" => @runtime_id})
      assert html =~ "environment"
      assert has_element?(view, "[id='library-path-#{@runtime_id}']")
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
