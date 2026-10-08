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

    test "renders the shared admin header and list", %{conn: conn} do
      {:ok, _list} =
        Mydia.ImportLists.create_import_list(%{
          name: "Header List #{System.unique_integer([:positive])}",
          type: "tmdb_trending",
          media_type: "movie"
        })

      {:ok, view, _} = live(conn, ~p"/admin/import-lists")

      assert has_element?(view, "#admin-page-title", "Import Lists")
      refute has_element?(view, "#admin-page-tabs")
      assert has_element?(view, "#import-lists.bg-base-200")
      assert has_element?(view, ".join-item[title=Sync]")
    end

    test "the items modal filters by status with a segmented control", %{conn: conn} do
      {:ok, list} =
        Mydia.ImportLists.create_import_list(%{
          name: "Items List #{System.unique_integer([:positive])}",
          type: "tmdb_trending",
          media_type: "movie"
        })

      {:ok, view, _} = live(conn, ~p"/admin/import-lists")

      view
      |> element("#view-import-list-items-#{list.id}")
      |> render_click()

      assert has_element?(view, "#import-list-items-modal")
      assert has_element?(view, "#import-list-items-filter")

      view
      |> element(~s{#import-list-items-filter button[phx-value-status="pending"]})
      |> render_click()

      assert has_element?(view, "#import-list-items-modal")
    end

    test "the nav link is present", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/quality")

      assert has_element?(view, "a#nav-import-lists[href='/admin/import-lists']")
    end

    test "the auto-add warning explains what turning it on does", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/import-lists")

      view
      |> element("button[phx-click='new_import_list']")
      |> render_click()

      assert has_element?(view, "#import-list-form")

      assert has_element?(
               view,
               "#import-list-form p.text-warning",
               "downloaded automatically"
             )
    end

    test "unchecking Enabled, Auto-add and Monitored persists false", %{conn: conn} do
      {:ok, list} =
        Mydia.ImportLists.create_import_list(%{
          name: "Toggle List #{System.unique_integer([:positive])}",
          type: "tmdb_trending",
          media_type: "movie",
          enabled: true,
          auto_add: true,
          monitored: true
        })

      {:ok, view, _html} = live(conn, ~p"/admin/import-lists")

      view
      |> element(~s{button[phx-click="edit_import_list"][phx-value-id="#{list.id}"]})
      |> render_click()

      view
      |> form("#import-list-form",
        import_list: %{"enabled" => "false", "auto_add" => "false", "monitored" => "false"}
      )
      |> render_submit()

      saved = Mydia.Repo.get!(Mydia.ImportLists.ImportList, list.id)
      refute saved.enabled
      refute saved.auto_add
      refute saved.monitored
    end
  end

  describe "with Import Lists disabled" do
    setup %{conn: conn} do
      put_import_lists_enabled(false)
      login_admin(conn)
    end

    test "mounting redirects instead of rendering the page", %{conn: conn} do
      assert {:error, {:redirect, redirect}} = live(conn, ~p"/admin/import-lists")

      assert redirect.to == ~p"/admin/status"
      assert redirect.flash["error"] =~ "disabled"
    end

    test "the nav link is absent", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/quality")

      refute has_element?(view, "a#nav-import-lists")
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
