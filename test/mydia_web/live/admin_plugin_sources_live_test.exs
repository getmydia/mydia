defmodule MydiaWeb.AdminPluginSourcesLiveTest do
  # async: false: connected LiveView under the sandbox, and the preview seam is
  # app-wide config.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MinisignFixtures, only: [keypair: 0, sign: 2]

  alias Mydia.Accounts
  alias Mydia.Plugins.Sources
  alias Mydia.Repo

  setup %{conn: conn} do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.create_user(%{
        email: "admin_#{unique}@example.com",
        username: "admin_#{unique}",
        password_hash: "$2b$12$test",
        role: "admin"
      })

    {:ok, token, _} = Mydia.Auth.Guardian.encode_and_sign(user)

    original_runtime = Application.get_env(:mydia, :runtime_config)
    original_opts = Application.get_env(:mydia, :plugin_source_preview_opts)

    on_exit(fn ->
      restore(:runtime_config, original_runtime)
      restore(:plugin_source_preview_opts, original_opts)
    end)

    conn =
      conn
      |> init_test_session(%{})
      |> put_session(:guardian_default_token, token)
      |> put_req_header("authorization", "Bearer #{token}")

    %{conn: conn}
  end

  defp restore(key, nil), do: Application.delete_env(:mydia, key)
  defp restore(key, value), do: Application.put_env(:mydia, key, value)

  describe "sources card" do
    test "lists the official index, locked", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/admin/plugins")
      assert has_element?(view, "#plugin-sources #source-row-official")
      refute has_element?(view, "#source-row-official button")
    end

    test "a declared source has no Remove; a UI source does", %{conn: conn} do
      {:ok, ui} =
        Sources.add_source(%{url: "https://ui.test/index.json", public_key: keypair().public})

      {:ok, decl} =
        Sources.add_source(%{url: "https://decl.test/index.json", public_key: keypair().public})

      decl |> Ecto.Changeset.change(declared: true) |> Repo.update!()

      {:ok, view, _} = live(conn, ~p"/admin/plugins")
      assert has_element?(view, "#remove-source-#{ui.id}")
      refute has_element?(view, "#remove-source-#{decl.id}")
      assert has_element?(view, "#source-row-#{decl.id}", "Declared")
    end

    test "adding a source previews, then pins the key on confirm", %{conn: conn} do
      bypass = Bypass.open()
      keys = keypair()

      body =
        Jason.encode!(%{
          "version" => 2,
          "name" => "Example Plugins",
          "public_key" => keys.public,
          "plugins" => []
        })

      Bypass.stub(bypass, "GET", "/index.json", &Plug.Conn.resp(&1, 200, body))

      Bypass.stub(
        bypass,
        "GET",
        "/index.json.minisig",
        &Plug.Conn.resp(&1, 200, sign(body, keys))
      )

      Application.put_env(:mydia, :plugin_source_preview_opts,
        allow_private: true,
        resolver: fn _ -> {:ok, [{127, 0, 0, 1}]} end
      )

      url = "http://allowed.test:#{bypass.port}/index.json"

      {:ok, view, _} = live(conn, ~p"/admin/plugins")
      view |> element("#add-source") |> render_click()
      view |> form("#add-source-form", %{"url" => url}) |> render_submit()
      render_async(view)

      assert has_element?(view, "#source-preview", "Example Plugins")
      view |> element("#confirm-source") |> render_click()

      assert [%{public_key: pinned, name: "Example Plugins"}] = Sources.list_sources()
      assert pinned == keys.public
    end

    test "a source that fails verification shows the error and saves nothing", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/admin/plugins")
      view |> element("#add-source") |> render_click()

      view
      |> form("#add-source-form", %{"url" => "http://insecure.test/index.json"})
      |> render_submit()

      render_async(view)

      assert has_element?(view, "#source-error")
      assert Sources.list_sources() == []
    end

    test "removing a source deletes the row", %{conn: conn} do
      {:ok, ui} =
        Sources.add_source(%{url: "https://ui.test/index.json", public_key: keypair().public})

      {:ok, view, _} = live(conn, ~p"/admin/plugins")
      view |> element("#remove-source-#{ui.id}") |> render_click()
      refute has_element?(view, "#source-row-#{ui.id}")
      assert Sources.list_sources() == []
    end
  end
end
