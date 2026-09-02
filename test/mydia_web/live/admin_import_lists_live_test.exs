defmodule MydiaWeb.AdminImportListsLiveTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures

  alias Mydia.Jobs.ImportListScheduler

  # Tests mutate the global :mydia, :features application env to flip the
  # ENABLE_IMPORT_LISTS flag on and off. Always save/restore it via on_exit
  # (see test/README.md, "Tests must not mutate global env") and keep this
  # module async: false so no concurrent test observes the mutated value.
  defp put_import_lists_enabled(value) do
    original = Application.get_env(:mydia, :features, [])

    Application.put_env(
      :mydia,
      :features,
      Keyword.put(original, :import_lists_enabled, value)
    )

    on_exit(fn -> Application.put_env(:mydia, :features, original) end)
  end

  defp login_admin(conn) do
    admin = admin_user_fixture()
    %{conn: log_in_user(conn, admin), admin: admin}
  end

  describe "with Import Lists enabled" do
    setup %{conn: conn} do
      put_import_lists_enabled(true)
      login_admin(conn)
    end

    test "an admin can load /admin/import-lists", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/import-lists")

      assert has_element?(view, "h1", "Import Lists")
    end

    test "the nav link is present", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/dashboard")

      assert has_element?(view, "a[href='/admin/import-lists']")
    end

    test "the auto-add warning explains what turning it on does", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/import-lists")

      view
      |> element("button[phx-click='new_list']")
      |> render_click()

      assert has_element?(view, "#import-list-form")

      assert has_element?(
               view,
               "#import-list-form p.text-warning",
               "downloaded automatically"
             )
    end
  end

  describe "with Import Lists disabled" do
    setup %{conn: conn} do
      put_import_lists_enabled(false)
      login_admin(conn)
    end

    test "mounting redirects instead of rendering the page", %{conn: conn} do
      assert {:error, {:redirect, redirect}} = live(conn, ~p"/admin/import-lists")

      assert redirect.to == ~p"/admin/dashboard"
      assert redirect.flash["error"] =~ "disabled"
    end

    test "the nav link is absent", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/dashboard")

      refute has_element?(view, "a[href='/admin/import-lists']")
    end
  end

  describe "Mydia.Jobs.ImportListScheduler.perform/1" do
    test "returns :ok without enqueueing when the flag is off" do
      put_import_lists_enabled(false)

      # Oban is not started in test (see test/README.md, "Oban is disabled in
      # test"), so this calls perform/1 directly with a hand-built job rather
      # than going through Oban.insert/enqueue.
      assert ImportListScheduler.perform(%Oban.Job{args: %{}}) == :ok
    end
  end
end
