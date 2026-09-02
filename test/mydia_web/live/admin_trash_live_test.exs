defmodule MydiaWeb.AdminTrashLiveTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Accounts
  alias Mydia.Library
  alias Mydia.Repo

  # Mirrors test/mydia_web/live/admin_duplicates_live_test.exs, the canonical
  # admin LiveView setup in this project.
  setup %{conn: conn, tmp_dir: tmp_dir} do
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
end
