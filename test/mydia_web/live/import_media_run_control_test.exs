defmodule MydiaWeb.ImportMediaRunControlTest do
  use MydiaWeb.ConnCase, async: false
  # Required for assert_enqueued/1. Oban runs testing: :manual in this app, so
  # jobs are inserted but never executed by the test run.
  use Oban.Testing, repo: Mydia.Repo

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Library

  setup %{conn: conn} do
    # The app skips Oban entirely in test env (see Mydia.Application), so
    # Oban.insert!/1 in the LiveView has nothing to resolve against unless we
    # start an isolated, manual-mode instance here. Same pattern as
    # test/mydia/jobs/segment_detection_test.exs.
    engine = if Mydia.DB.postgres?(), do: Oban.Engines.Basic, else: Oban.Engines.Lite
    start_supervised!({Oban, repo: Mydia.Repo, engine: engine, testing: :manual})

    # Roles are strings in this app: ~w(admin user readonly guest).
    user = user_fixture(%{role: "admin"})
    library_path = library_path_fixture()

    {:ok, conn: log_in_user(conn, user), user: user, library_path: library_path}
  end

  test "renders the run control", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/import")

    assert has_element?(view, "#import-run-control")
    assert has_element?(view, "#start-run-button")
  end

  test "starting a run creates it and enqueues the coordinator", %{
    conn: conn,
    library_path: lp
  } do
    {:ok, view, _html} = live(conn, ~p"/import")

    view
    |> element("#start-run-form")
    |> render_submit(%{"library_path_id" => lp.id, "mode" => "review"})

    assert Library.active_import_run(lp.id)
    assert_enqueued(worker: Mydia.Jobs.ImportRun, queue: :imports)
  end

  test "shows stop while a run is active", %{conn: conn, library_path: lp, user: user} do
    {:ok, _run} =
      Library.create_import_run(%{library_path_id: lp.id, user_id: user.id, mode: :review})

    {:ok, view, _html} = live(conn, ~p"/import")

    assert has_element?(view, "#stop-run-button")
  end

  test "stopping asks the run to stop", %{conn: conn, library_path: lp, user: user} do
    {:ok, run} =
      Library.create_import_run(%{library_path_id: lp.id, user_id: user.id, mode: :review})

    {:ok, view, _html} = live(conn, ~p"/import")

    view |> element("#stop-run-button") |> render_click()

    assert Library.get_import_run(run.id).status == :stopping
  end

  test "re-attaches to a run in flight after a reload", %{
    conn: conn,
    library_path: lp,
    user: user
  } do
    {:ok, run} =
      Library.create_import_run(%{library_path_id: lp.id, user_id: user.id, mode: :unattended})

    {:ok, _} = Library.update_import_run(run, %{files_discovered: 4_200})

    {:ok, view, _html} = live(conn, ~p"/import")

    assert render(view) =~ "4,200"
  end
end
