defmodule MydiaWeb.ImportMediaRunControlTest do
  use MydiaWeb.ConnCase, async: false
  # Required for assert_enqueued/1. Oban runs testing: :manual in this app, so
  # jobs are inserted but never executed by the test run.
  use Oban.Testing, repo: Mydia.Repo

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures
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

  test "starting a run while another tab already started one shows a friendly message and does not create a duplicate",
       %{conn: conn, library_path: lp, user: user} do
    {:ok, view, _html} = live(conn, ~p"/import")

    # Simulate a second tab winning the race: a run for this library path
    # exists in the database by the time this (stale) view submits, even
    # though this view's own socket state never learned about it -- exactly
    # what happens when two browser tabs both have the start form open.
    {:ok, existing} =
      Library.create_import_run(%{library_path_id: lp.id, user_id: user.id, mode: :review})

    html =
      view
      |> element("#start-run-form")
      |> render_submit(%{"library_path_id" => lp.id, "mode" => "review"})

    assert html =~ "That library is already being imported."

    # The second assertion is the one that matters: a broken implementation
    # that swallowed the error and inserted a duplicate row anyway would
    # still show no crash and would still make the first assertion alone
    # pass.
    assert Library.active_import_run(lp.id).id == existing.id
  end

  test "a mode the server does not recognise is refused instead of killing the page", %{
    conn: conn,
    library_path: lp
  } do
    {:ok, view, _html} = live(conn, ~p"/import")

    # A tab left open across a deploy that renamed a mode, a replayed event, or
    # a crafted one. Converting this straight to an atom raises, and a raise in
    # a handler takes the LiveView process with it: the user's page closes
    # instead of answering them.
    html =
      view
      |> element("#start-run-form")
      |> render_submit(%{"library_path_id" => lp.id, "mode" => "not_a_real_mode_9f3"})

    assert html =~ "That import mode is not available."
    refute Library.active_import_run(lp.id)
  end

  test "stopping a run that finished in the meantime does not lock the path", %{
    conn: conn,
    library_path: lp,
    user: user
  } do
    {:ok, run} =
      Library.create_import_run(%{library_path_id: lp.id, user_id: user.id, mode: :review})

    {:ok, view, _html} = live(conn, ~p"/import")

    # The coordinator reaches :done after this view rendered its Stop button.
    {:ok, _} = Library.update_import_run(run, %{status: :done, phase: :finished})

    view |> element("#stop-run-button") |> render_click()

    # Writing :stopping here would be a permanent lockout: :stopping counts as
    # active, and no worker is left alive to advance it.
    assert Library.get_import_run(run.id).status == :done
    refute Library.active_import_run(lp.id)
  end

  test "renders one selectable library card per path, with an icon", %{
    conn: conn,
    library_path: lp
  } do
    {:ok, view, _html} = live(conn, ~p"/import")

    assert has_element?(
             view,
             "label.card input[type=radio][name=library_path_id][value='#{lp.id}']"
           )

    # The first path is preselected so the form always submits a real id.
    assert has_element?(
             view,
             "input[type=radio][name=library_path_id][value='#{lp.id}'][checked]"
           )
  end

  describe "library types that cannot be imported" do
    # The start form used to filter out music, books and adult paths, and a
    # crafted event naming one directly had to be refused too. Those types no
    # longer exist, so there is nothing left to filter and no such path can be
    # built -- library_path_fixture validates against the same enum the form
    # reads. What survives is the shape of the check: every type the schema
    # allows is offered, and an id outside the offered set is still refused.
    test "every type the schema allows is offered in the start form", %{conn: conn} do
      paths =
        for type <- Ecto.Enum.values(Mydia.Settings.LibraryPath, :type) do
          library_path_fixture(%{type: to_string(type), name: "Lib #{type}"})
        end

      {:ok, view, _html} = live(conn, ~p"/import")

      html = render(view)

      for path <- paths, do: assert(html =~ path.path)
    end

    test "an id outside the offered set is refused", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/import")

      view
      |> element("#start-run-form")
      |> render_submit(%{"library_path_id" => Ecto.UUID.generate(), "mode" => "unattended"})

      assert Mydia.Repo.aggregate(Mydia.Library.ImportRun, :count) == 0
    end
  end

  test "a reload after a failed run shows the outcome instead of a blank form", %{
    conn: conn,
    library_path: lp,
    user: user
  } do
    {:ok, run} =
      Library.create_import_run(%{library_path_id: lp.id, user_id: user.id, mode: :review})

    {:ok, _} =
      Library.update_import_run(run, %{
        status: :failed,
        phase: :finished,
        files_discovered: 12,
        error: ":not_found"
      })

    {:ok, view, _html} = live(conn, ~p"/import")

    assert has_element?(view, "#run-outcome")
    assert render(view) =~ ":not_found"
  end

  test "outcome panel shows review CTA when unresolved files exist for the library path", %{
    conn: conn,
    library_path: lp,
    user: user
  } do
    media_file = orphaned_media_file_fixture(%{library_path_id: lp.id})

    {:ok, _} =
      Library.upsert_match_candidate(%{
        media_file_id: media_file.id,
        rank: 0,
        provider_type: "tmdb",
        provider_id: "603",
        title: "The Matrix",
        confidence: 0.95
      })

    {:ok, run} =
      Library.create_import_run(%{library_path_id: lp.id, user_id: user.id, mode: :review})

    {:ok, _} =
      Library.update_import_run(run, %{
        status: :done,
        phase: :finished,
        files_discovered: 1,
        files_matched: 1,
        files_linked: 0
      })

    {:ok, view, _html} = live(conn, ~p"/import")

    assert has_element?(
             view,
             "#run-outcome a[href='/import']",
             "Review 1 file(s) that need attention"
           )
  end

  test "outcome panel hides review CTA when no unresolved files exist", %{
    conn: conn,
    library_path: lp,
    user: user
  } do
    {:ok, run} =
      Library.create_import_run(%{library_path_id: lp.id, user_id: user.id, mode: :review})

    {:ok, _} =
      Library.update_import_run(run, %{
        status: :done,
        phase: :finished,
        files_discovered: 1,
        files_matched: 1,
        files_linked: 1
      })

    {:ok, view, _html} = live(conn, ~p"/import")

    assert has_element?(view, "#run-outcome")
    refute has_element?(view, "#run-outcome a[href='/import']")
  end
end
