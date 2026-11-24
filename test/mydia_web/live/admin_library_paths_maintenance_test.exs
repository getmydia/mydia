defmodule MydiaWeb.AdminLibraryPathsMaintenanceTest do
  use MydiaWeb.ConnCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  import Phoenix.LiveViewTest
  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Accounts

  @moduletag :tmp_dir

  setup %{conn: conn, tmp_dir: tmp_dir} do
    engine = if Mydia.DB.postgres?(), do: Oban.Engines.Basic, else: Oban.Engines.Lite
    start_supervised!({Oban, repo: Mydia.Repo, engine: engine, testing: :manual})
    start_supervised!(Mydia.Indexers.Health)

    previous = Application.get_env(:mydia, :trash_dir)
    Application.put_env(:mydia, :trash_dir, Path.join(tmp_dir, "trash"))

    on_exit(fn ->
      if previous,
        do: Application.put_env(:mydia, :trash_dir, previous),
        else: Application.delete_env(:mydia, :trash_dir)
    end)

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

    root = Path.join(tmp_dir, "lib")
    File.mkdir_p!(root)
    lp = library_path_fixture(%{path: root, type: "mixed"})
    movie = media_item_fixture(%{type: "movie", title: "Paper Comet", year: 2019})

    rel = "paper.comet.junk.mkv"
    File.write!(Path.join(root, rel), "video")

    media_file_fixture(%{media_item_id: movie.id, library_path_id: lp.id, relative_path: rel})

    orphan = Path.join(root, "gone.video.nfo")
    File.write!(orphan, "x")

    {:ok, view, _html} = live(conn, ~p"/admin/library-paths")
    %{conn: conn, view: view, lp: lp, orphan: orphan}
  end

  test "rename preview shows counts and sample", %{view: view, lp: lp} do
    view |> element("#rename-files-#{lp.id}") |> render_click()
    render_async(view)

    assert has_element?(view, "#bulk-rename-modal")
    assert has_element?(view, "#bulk-rename-sample")
    assert has_element?(view, "#bulk-rename-confirm:not([disabled])")
  end

  test "confirming rename enqueues LibraryRename", %{view: view, lp: lp} do
    view |> element("#rename-files-#{lp.id}") |> render_click()
    render_async(view)
    view |> element("#bulk-rename-confirm") |> render_click()

    assert_enqueued(worker: Mydia.Jobs.LibraryRename, args: %{library_path_id: lp.id})
    refute has_element?(view, "#bulk-rename-modal")
    assert has_element?(view, "#renaming-#{lp.id}")
  end

  test "cleanup preview lists the orphan and its destination", %{view: view, lp: lp, orphan: o} do
    view |> element("#cleanup-sidecars-#{lp.id}") |> render_click()
    render_async(view)

    assert has_element?(view, "#sidecar-cleanup-modal")
    assert has_element?(view, "#sidecar-cleanup-destination")
    assert render(view) =~ Path.basename(o)
  end

  test "confirming cleanup enqueues SidecarCleanup with the shown paths", %{
    view: view,
    lp: lp,
    orphan: orphan
  } do
    view |> element("#cleanup-sidecars-#{lp.id}") |> render_click()
    render_async(view)
    view |> element("#sidecar-cleanup-confirm") |> render_click()

    assert_enqueued(
      worker: Mydia.Jobs.SidecarCleanup,
      args: %{library_path_id: lp.id, paths: [orphan]}
    )

    assert has_element?(view, "#cleaning-#{lp.id}")
  end

  test "the cleanup action is absent on an s3 library", %{conn: conn} do
    {:ok, _} =
      Mydia.Settings.create_storage_backend(%{
        name: "media",
        endpoint: "http://localhost:1",
        region: "us-east-1",
        bucket: "lib",
        access_key_id: "k",
        secret_access_key: "s",
        path_style: true
      })

    s3 = library_path_fixture(%{path: "s3://media/movies", type: "movies"})
    {:ok, view, _html} = live(conn, ~p"/admin/library-paths")

    assert has_element?(view, "#rename-files-#{s3.id}")
    refute has_element?(view, "#cleanup-sidecars-#{s3.id}")
  end

  test "a completion broadcast clears the badge and flashes", %{view: view, lp: lp} do
    send(view.pid, {:library_rename_started, %{library_path_id: lp.id}})
    assert render(view) =~ "renaming-#{lp.id}"

    send(
      view.pid,
      {:library_rename_completed,
       %{library_path_id: lp.id, renamed: 1, unchanged: 0, conflicts: 0, errors: 0}}
    )

    html = render(view)
    refute html =~ "renaming-#{lp.id}"
    assert html =~ "Renamed 1 files, 0 conflicts, 0 errors"
  end

  test "a failed completion flashes an error", %{view: view, lp: lp} do
    send(
      view.pid,
      {:sidecar_cleanup_completed,
       %{
         library_path_id: lp.id,
         moved: 0,
         kept: 0,
         container: nil,
         error: :library_unavailable
       }}
    )

    assert render(view) =~ "Cleanup failed: library unavailable"
  end
end
