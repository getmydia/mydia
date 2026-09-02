defmodule MydiaWeb.AdminTrashLiveTest do
  use MydiaWeb.ConnCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  import Phoenix.LiveViewTest
  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Accounts
  alias Mydia.Library
  alias Mydia.Repo

  # Mirrors test/mydia_web/live/admin_duplicates_live_test.exs, the canonical
  # admin LiveView setup in this project.
  setup %{conn: conn, tmp_dir: tmp_dir} do
    engine = if Mydia.DB.postgres?(), do: Oban.Engines.Basic, else: Oban.Engines.Lite
    start_supervised!({Oban, repo: Mydia.Repo, engine: engine, testing: :manual})

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

    trash_root = Path.join(tmp_dir, "trash")
    File.mkdir_p!(trash_root)
    Application.put_env(:mydia, :trash_dir, trash_root)
    on_exit(fn -> Application.delete_env(:mydia, :trash_dir) end)

    root = Path.join(tmp_dir, "lib")
    File.mkdir_p!(root)
    library_path = library_path_fixture(%{path: root, type: "movies"})

    %{conn: conn, user: user, root: root, library_path: library_path}
  end

  defp trashed(ctx, name, reason, size) do
    File.write!(Path.join(ctx.root, name), String.duplicate("x", size))

    {:ok, media_file} =
      Library.create_scanned_media_file(%{
        relative_path: name,
        library_path_id: ctx.library_path.id,
        media_item_id: media_item_fixture(%{type: "movie", title: "The Vermilion Hour"}).id,
        size: size
      })

    {:ok, trashed} =
      Library.trash_media_file(Repo.preload(media_file, :library_path), reason: reason)

    trashed
  end

  # A TV episode's media_file carries episode_id with media_item_id NULL; the
  # show lives at episode.media_item. A movie fixture (see trashed/4 above)
  # cannot exercise that shape, which is why the label regressed twice
  # before without a test catching it.
  defp trashed_episode(ctx, name, reason, size) do
    series_root = Path.join(ctx.root, "series")
    File.mkdir_p!(series_root)
    series_library_path = library_path_fixture(%{path: series_root, type: "series"})

    File.write!(Path.join(series_root, name), String.duplicate("x", size))

    show = media_item_fixture(%{type: "tv_show", title: "Nightfall Harbor"})
    episode = episode_fixture(%{media_item_id: show.id, season_number: 2, episode_number: 4})

    {:ok, media_file} =
      Library.create_scanned_media_file(%{
        relative_path: name,
        library_path_id: series_library_path.id,
        episode_id: episode.id,
        size: size
      })

    {:ok, trashed} =
      Library.trash_media_file(Repo.preload(media_file, :library_path), reason: reason)

    trashed
  end

  @tag :tmp_dir
  test "renders the trash page with a summary", %{conn: conn} = ctx do
    _a = trashed(ctx, "a.mkv", :missing, 10)

    {:ok, view, _html} = live(conn, ~p"/admin/config/trash")

    assert has_element?(view, "#trash-summary")
    assert has_element?(view, "#trash-list")
  end

  @tag :tmp_dir
  test "lists a trashed file with its reason", %{conn: conn} = ctx do
    file = trashed(ctx, "a.mkv", :pruned, 10)

    {:ok, view, _html} = live(conn, ~p"/admin/config/trash")

    assert has_element?(view, "#trash-row-#{file.id}")
    assert has_element?(view, "#trash-reason-#{file.id}")
  end

  @tag :tmp_dir
  test "filters by reason", %{conn: conn} = ctx do
    missing = trashed(ctx, "a.mkv", :missing, 10)
    pruned = trashed(ctx, "b.mkv", :pruned, 10)

    {:ok, view, _html} = live(conn, ~p"/admin/config/trash")

    view |> element("#trash-filter-pruned") |> render_click()

    assert has_element?(view, "#trash-row-#{pruned.id}")
    refute has_element?(view, "#trash-row-#{missing.id}")
  end

  @tag :tmp_dir
  test "filters by the unknown reason chip", %{conn: conn} = ctx do
    # Task 3's list_trashed_media_files(reason: :unknown) had no coverage
    # anywhere. A row trashed with no reason recorded is the only way to
    # exercise it from the page, so this test builds one directly rather
    # than through trashed/4, which always passes a reason.
    File.write!(Path.join(ctx.root, "c.mkv"), String.duplicate("x", 10))

    {:ok, media_file} =
      Library.create_scanned_media_file(%{
        relative_path: "c.mkv",
        library_path_id: ctx.library_path.id,
        media_item_id: media_item_fixture(%{type: "movie", title: "The Vermilion Hour"}).id,
        size: 10
      })

    {:ok, unknown} =
      Library.trash_media_file(Repo.preload(media_file, :library_path), reason: nil)

    pruned = trashed(ctx, "b.mkv", :pruned, 10)

    {:ok, view, _html} = live(conn, ~p"/admin/config/trash")

    view |> element("#trash-filter-unknown") |> render_click()

    assert has_element?(view, "#trash-row-#{unknown.id}")
    refute has_element?(view, "#trash-row-#{pruned.id}")
  end

  @tag :tmp_dir
  test "labels a trashed TV episode with the show title and episode number, not the file path",
       %{conn: conn} = ctx do
    file = trashed_episode(ctx, "episode.mkv", :upgraded, 10)

    {:ok, view, _html} = live(conn, ~p"/admin/config/trash")

    row = view |> element("#trash-row-#{file.id}") |> render()

    assert row =~ "Nightfall Harbor S02E04"
    refute row =~ "episode.mkv"
  end

  @tag :tmp_dir
  test "restores a file", %{conn: conn} = ctx do
    file = trashed(ctx, "a.mkv", :missing, 10)

    {:ok, view, _html} = live(conn, ~p"/admin/config/trash")

    view |> element("#trash-restore-#{file.id}") |> render_click()

    refute has_element?(view, "#trash-row-#{file.id}")
    assert is_nil(Repo.reload(file).trashed_at)
  end

  @tag :tmp_dir
  test "purges a file permanently", %{conn: conn} = ctx do
    file = trashed(ctx, "a.mkv", :pruned, 10)
    trash_path = file.metadata.extra["trashed_path"]

    {:ok, view, _html} = live(conn, ~p"/admin/config/trash")

    view |> element("#trash-purge-#{file.id}") |> render_click()

    refute has_element?(view, "#trash-row-#{file.id}")
    assert is_nil(Repo.get(Mydia.Library.MediaFile, file.id))
    refute File.exists?(trash_path)
  end

  @tag :tmp_dir
  test "empty trash asks first, then purges everything", %{conn: conn} = ctx do
    file = trashed(ctx, "a.mkv", :pruned, 10)

    {:ok, view, _html} = live(conn, ~p"/admin/config/trash")

    view |> element("#trash-empty") |> render_click()
    assert has_element?(view, "#trash-empty-modal")

    view |> element("#trash-empty-confirm") |> render_click()

    assert is_nil(Repo.get(Mydia.Library.MediaFile, file.id))
  end

  describe "bulk actions" do
    @tag :tmp_dir
    test "selecting a row shows the bulk bar", %{conn: conn} = ctx do
      file = trashed(ctx, "a.mkv", :missing, 10)

      {:ok, view, _html} = live(conn, ~p"/admin/config/trash")

      refute has_element?(view, "#trash-bulk-bar")
      view |> element("#trash-select-#{file.id}") |> render_click()
      assert has_element?(view, "#trash-bulk-bar")
    end

    @tag :tmp_dir
    test "select-all-matching only appears past one page", %{conn: conn} = ctx do
      file = trashed(ctx, "a.mkv", :missing, 10)

      {:ok, view, _html} = live(conn, ~p"/admin/config/trash")
      view |> element("#trash-select-#{file.id}") |> render_click()

      # One row fits on a page, so there is nothing off-screen to select.
      refute has_element?(view, "#trash-select-all-matching")
    end

    @tag :tmp_dir
    test "bulk restore enqueues a job", %{conn: conn} = ctx do
      file = trashed(ctx, "a.mkv", :missing, 10)

      {:ok, view, _html} = live(conn, ~p"/admin/config/trash")
      view |> element("#trash-select-#{file.id}") |> render_click()
      view |> element("#trash-bulk-restore") |> render_click()

      assert_enqueued(worker: Mydia.Jobs.TrashAction)
    end

    @tag :tmp_dir
    test "switching the reason filter clears a select-all-matching selection",
         %{conn: conn} = ctx do
      for n <- 1..60, do: trashed(ctx, "m#{n}.mkv", :missing, 10)
      pruned = trashed(ctx, "p.mkv", :pruned, 10)

      {:ok, view, _html} = live(conn, ~p"/admin/config/trash")

      html = view |> element("#trash-filter-missing") |> render_click()

      # The bulk bar, and the "select all matching" button inside it, only
      # render once something is selected; tick one visible row first so the
      # button appears, then reach for "select all" to get the rest.
      one_visible_id = html |> row_ids() |> Enum.at(0)
      view |> element("#trash-select-#{one_visible_id}") |> render_click()
      view |> element("#trash-select-all-matching") |> render_click()
      assert has_element?(view, "#trash-bulk-bar")

      # {:all_matching, :missing} must not survive a switch to Pruned: the
      # tuple carries the reason it was made under, and enqueuing it after
      # the filter moved on would purge or restore the wrong 60 files while
      # the bar shows a small, unrelated Pruned count instead.
      html = view |> element("#trash-filter-pruned") |> render_click()

      refute has_element?(view, "#trash-bulk-bar")
      refute checked?(html, "trash-select-#{pruned.id}")
    end
  end

  describe "pagination" do
    @tag :tmp_dir
    test "a second page is reachable and shows different rows", %{conn: conn} = ctx do
      for n <- 1..60, do: trashed(ctx, "f#{n}.mkv", :missing, 10)

      {:ok, view, html} = live(conn, ~p"/admin/config/trash")

      assert has_element?(view, "#trash-pagination")
      assert has_element?(view, "#trash-page-next")

      first_page_ids = row_ids(html)
      assert MapSet.size(first_page_ids) == 50

      html = view |> element("#trash-page-next") |> render_click()
      second_page_ids = row_ids(html)

      assert MapSet.size(second_page_ids) == 10
      assert MapSet.disjoint?(first_page_ids, second_page_ids)
    end

    # Every action on this page removes rows, so the offset in assigns can
    # outrun the result set it was computed against. Restoring the only row on
    # page 2 of 51 used to reload at offset 50 with 50 rows left, rendering an
    # empty page and "Showing 51-50 of 50".
    @tag :tmp_dir
    test "emptying the last page falls back to the page before it", %{conn: conn} = ctx do
      for n <- 1..51, do: trashed(ctx, "f#{n}.mkv", :missing, 10)

      {:ok, view, _html} = live(conn, ~p"/admin/config/trash")

      html = view |> element("#trash-page-next") |> render_click()
      [only] = html |> row_ids() |> MapSet.to_list()

      html = view |> element("#trash-restore-#{only}") |> render_click()

      assert MapSet.size(row_ids(html)) == 50
      refute has_element?(view, "#trash-row-#{only}")
    end
  end

  defp row_ids(html) do
    ~r/id="trash-row-([^"]+)"/
    |> Regex.scan(html)
    |> Enum.map(fn [_, id] -> id end)
    |> MapSet.new()
  end

  defp checked?(html, id) do
    case Regex.run(~r/<input[^>]*id="#{id}"[^>]*>/, html) do
      [tag] -> tag =~ "checked"
      nil -> false
    end
  end
end
