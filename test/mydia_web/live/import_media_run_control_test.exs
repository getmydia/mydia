defmodule MydiaWeb.ImportMediaRunControlTest do
  use MydiaWeb.ConnCase, async: false
  # Required for assert_enqueued/1. Oban runs testing: :manual in this app, so
  # jobs are inserted but never executed by the test run.
  use Oban.Testing, repo: Mydia.Repo

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.ImportGroups
  alias Mydia.Library
  alias Mydia.Library.ImportGroup
  alias Mydia.Repo

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

  defp import_group(library_path, attrs) do
    defaults = %{
      library_path_id: library_path.id,
      anchor_path: "Show",
      cluster_key: Ecto.UUID.generate(),
      display_title: "Show",
      file_count: 1,
      unresolved_count: 1,
      status: "pending"
    }

    %ImportGroup{}
    |> ImportGroup.changeset(Map.merge(defaults, Map.new(attrs)))
    |> Repo.insert!()
  end

  test "renders the run control", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/import")

    assert has_element?(view, "#import-run-control")
    assert has_element?(view, "#start-run-button")
  end

  test "uses one library selector for both scanning and review", %{
    conn: conn,
    library_path: lp
  } do
    {:ok, view, _html} = live(conn, ~p"/import?library_path_id=#{lp.id}")

    assert has_element?(view, "#library-tabs")
    assert has_element?(view, "#library-tab-#{lp.id}.tab-active")

    assert has_element?(
             view,
             "#start-run-form input[type=hidden][name=library_path_id][value='#{lp.id}']"
           )

    refute has_element?(view, "#start-run-form input[type=radio][name=library_path_id]")
  end

  test "automatic import is an on-by-default toggle instead of a mode dropdown", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/import")

    assert has_element?(
             view,
             "#auto-import-toggle[type=checkbox][name=auto_import][value=true][checked]"
           )

    refute has_element?(view, "#start-run-mode")
  end

  test "checked automatic import starts an unattended run", %{
    conn: conn,
    library_path: lp
  } do
    {:ok, view, _html} = live(conn, ~p"/import")

    view
    |> element("#start-run-form")
    |> render_submit(%{
      "library_path_id" => lp.id,
      "mode" => "review",
      "auto_import" => "true"
    })

    assert Library.active_import_run(lp.id).mode == :unattended
  end

  test "disabled automatic import starts a review run", %{
    conn: conn,
    library_path: lp
  } do
    {:ok, view, _html} = live(conn, ~p"/import")

    view
    |> element("#start-run-form")
    |> render_submit(%{"library_path_id" => lp.id, "auto_import" => "false"})

    assert Library.active_import_run(lp.id).mode == :review
  end

  test "an active scan takes focus and hides review controls", %{
    conn: conn,
    library_path: lp,
    user: user
  } do
    {:ok, _run} =
      Library.create_import_run(%{library_path_id: lp.id, user_id: user.id, mode: :review})

    {:ok, view, _html} = live(conn, ~p"/import?library_path_id=#{lp.id}")

    assert has_element?(view, "#run-progress")
    refute has_element?(view, "#band-all")
  end

  test "scan state is scoped to the selected library", %{
    conn: conn,
    library_path: selected,
    user: user
  } do
    other =
      library_path_fixture(%{
        type: "movies",
        path: "/tmp/other_import_library_#{System.unique_integer([:positive])}"
      })

    {:ok, _run} =
      Library.create_import_run(%{
        library_path_id: other.id,
        user_id: user.id,
        mode: :unattended
      })

    {:ok, view, _html} = live(conn, ~p"/import?library_path_id=#{selected.id}")

    assert has_element?(view, "#start-run-button")
    refute has_element?(view, "#run-progress")
  end

  test "start scan cannot target a different library than the selected tab", %{
    conn: conn,
    library_path: selected
  } do
    other =
      library_path_fixture(%{
        type: "series",
        path: "/tmp/unselected_import_library_#{System.unique_integer([:positive])}"
      })

    {:ok, view, _html} = live(conn, ~p"/import?library_path_id=#{selected.id}")

    view
    |> element("#start-run-form")
    |> render_submit(%{"library_path_id" => other.id, "auto_import" => "true"})

    refute Library.active_import_run(other.id)
    refute Library.active_import_run(selected.id)
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

  test "re-attaches to a run in flight after a reload without noisy counters", %{
    conn: conn,
    library_path: lp,
    user: user
  } do
    {:ok, run} =
      Library.create_import_run(%{library_path_id: lp.id, user_id: user.id, mode: :unattended})

    {:ok, _} = Library.update_import_run(run, %{files_discovered: 4_200})

    {:ok, view, _html} = live(conn, ~p"/import")

    assert has_element?(view, "#run-progress", "Finding files")
    refute has_element?(view, "#run-progress", "Found")
    refute has_element?(view, "#run-progress", "Matched")
    refute has_element?(view, "#run-progress", "Added")
  end

  test "a completed run immediately refreshes the review groups", %{
    conn: conn,
    library_path: lp,
    user: user
  } do
    {:ok, run} =
      Library.create_import_run(%{library_path_id: lp.id, user_id: user.id, mode: :review})

    {:ok, view, _html} = live(conn, ~p"/import")

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

    {:ok, _} = ImportGroups.upsert_for_library(lp, import_run_id: run.id)
    {[group], nil} = ImportGroups.page(lp.id)

    refute has_element?(view, "#group-#{group.id}")

    {:ok, finished} =
      Library.update_import_run(run, %{status: :done, phase: :finished, files_matched: 1})

    send(view.pid, {:import_run_progress, finished})

    assert has_element?(view, "#group-#{group.id}")
    assert has_element?(view, "#band-all .badge", "1")
    assert has_element?(view, "#review-section")
    assert has_element?(view, "#review-heading #scan-complete-status", "Scan complete")
    refute has_element?(view, "#import-run-control", "Scan complete")

    send(view.pid, {:dismiss_scan_complete, Ecto.UUID.generate()})
    assert has_element?(view, "#scan-complete-status", "Scan complete")

    send(view.pid, {:dismiss_scan_complete, finished.id})
    render(view)
    refute has_element?(view, "#scan-complete-status")
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

  test "an unrecognised automatic import value safely falls back to review mode", %{
    conn: conn,
    library_path: lp
  } do
    {:ok, view, _html} = live(conn, ~p"/import")

    view
    |> element("#start-run-form")
    |> render_submit(%{"library_path_id" => lp.id, "auto_import" => "not-a-boolean"})

    assert Library.active_import_run(lp.id).mode == :review
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

  test "renders one selectable library tab per path, with an icon", %{
    conn: conn,
    library_path: lp
  } do
    {:ok, view, _html} = live(conn, ~p"/import")

    assert has_element?(view, "#library-tab-#{lp.id}.tab-active .hero-film")
  end

  describe "library types that cannot be imported" do
    # The start form used to filter out music, books and adult paths, and a
    # crafted event naming one directly had to be refused too. Those types no
    # longer exist, so there is nothing left to filter and no such path can be
    # built -- library_path_fixture validates against the same enum the form
    # reads. What survives is the shape of the check: every type the schema
    # allows is offered, and an id outside the offered set is still refused.
    test "every type the schema allows is offered in the library tabs", %{conn: conn} do
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

  test "a completed scan status is not restored on reload",
       %{
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

    # The summary reads `import_groups`, same as the review section beneath it,
    # so a bare MatchCandidate is not enough to produce a review count.
    {:ok, _} = ImportGroups.upsert_for_library(lp)

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

    refute has_element?(view, "#run-outcome")
    refute has_element?(view, "#scan-complete-status")
    assert has_element?(view, "#band-all .badge", "1")
    assert has_element?(view, "#start-run-form")
  end

  test "a completed scan with nothing to review restores neither outcome nor status", %{
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

    refute has_element?(view, "#run-outcome")
    refute has_element?(view, "#scan-complete-status")
    assert has_element?(view, "#start-run-form")
  end

  test "clear results removes the selected library's scan outcome and review groups", %{
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

    {:ok, _} = ImportGroups.upsert_for_library(lp)
    {[group], nil} = ImportGroups.page(lp.id)

    {:ok, run} =
      Library.create_import_run(%{library_path_id: lp.id, user_id: user.id, mode: :review})

    {:ok, _} = Library.update_import_run(run, %{status: :done, phase: :finished})

    {:ok, view, _html} = live(conn, ~p"/import?library_path_id=#{lp.id}")

    assert has_element?(view, "#group-#{group.id}")
    assert has_element?(view, "#review-section #clear-scan-results")
    refute has_element?(view, "#start-run-form #clear-scan-results")

    assert Library.list_unmatched_media_file_paths(lp.id, 10) == []

    html =
      view
      |> element("#clear-scan-results")
      |> render_click()

    refute has_element?(view, "#run-outcome")
    refute has_element?(view, "#group-#{group.id}")
    assert has_element?(view, "#no-groups", "Nothing to review")
    refute Library.last_import_run(lp.id)

    # The point of clearing: the cached verdict goes too, so the next scan
    # re-matches this file instead of rebuilding the same group from it.
    assert Library.list_match_candidates(media_file.id) == []
    file_id = media_file.id
    assert [{^file_id, _path}] = Library.list_unmatched_media_file_paths(lp.id, 10)

    assert html =~ "cached match(es)"
  end

  test "import all accepts every provider-matched result only for the selected library", %{
    conn: conn,
    library_path: selected
  } do
    confident =
      import_group(selected,
        display_title: "Confident",
        provider_type: "tmdb",
        provider_id: "1",
        min_confidence: 0.99
      )

    uncertain =
      import_group(selected,
        display_title: "Uncertain",
        provider_type: "tmdb",
        provider_id: "2",
        min_confidence: 0.55
      )

    unmatched = import_group(selected, display_title: "Unmatched")

    local =
      import_group(selected,
        display_title: "Local",
        provider_type: "local",
        provider_id: "local-item"
      )

    other_library = library_path_fixture(%{type: "movies"})

    other =
      import_group(other_library,
        display_title: "Other library",
        provider_type: "tmdb",
        provider_id: "3",
        min_confidence: 0.99
      )

    {:ok, view, _html} = live(conn, ~p"/import?library_path_id=#{selected.id}")

    assert has_element?(view, "#review-actions #import-all-results")
    assert has_element?(view, "#review-actions #clear-scan-results")

    view
    |> element("#import-all-results")
    |> render_click()

    assert Repo.reload!(confident).status == "accepted"
    assert Repo.reload!(uncertain).status == "accepted"
    assert Repo.reload!(unmatched).status == "pending"
    assert Repo.reload!(local).status == "pending"
    assert Repo.reload!(other).status == "pending"

    assert_enqueued(
      worker: Mydia.Jobs.ApplyImportGroups,
      args: %{"library_path_id" => selected.id}
    )
  end

  test "scan controls and review are both visible while idle", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/import")

    assert has_element?(view, "#start-run-button")
    assert has_element?(view, "#review-section")
  end

  test "scan controls stay compact above review items", %{
    conn: conn,
    library_path: lp
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

    {:ok, _} = ImportGroups.upsert_for_library(lp)

    {:ok, view, _html} = live(conn, ~p"/import")

    assert has_element?(view, "#start-run-button")
    assert has_element?(view, "#review-section")
  end

  test "an active library tab shows scan activity", %{
    conn: conn,
    library_path: lp,
    user: user
  } do
    {:ok, _run} =
      Library.create_import_run(%{library_path_id: lp.id, user_id: user.id, mode: :review})

    {:ok, view, _html} = live(conn, ~p"/import")

    assert has_element?(view, "#library-tab-#{lp.id} .loading-spinner")
  end

  test "pre-selects movie library tab when type=movies query param is provided", %{
    conn: conn,
    library_path: setup_library
  } do
    {:ok, _setup_library} = Mydia.Settings.update_library_path(setup_library, %{type: "series"})

    lp_tv =
      library_path_fixture(%{
        type: "series",
        path: "/tmp/lib_tv_#{System.unique_integer([:positive])}"
      })

    lp_movie =
      library_path_fixture(%{
        type: "movies",
        path: "/tmp/lib_movie_#{System.unique_integer([:positive])}"
      })

    {:ok, view, _html} = live(conn, ~p"/import?type=movies")

    assert has_element?(view, "#library-tab-#{lp_movie.id}.tab-active")
    refute has_element?(view, "#library-tab-#{lp_tv.id}.tab-active")
    assert has_element?(view, "input[name='library_path_id'][value='#{lp_movie.id}']")
  end

  test "pre-selects tv library tab when type=tv query param is provided", %{
    conn: conn
  } do
    lp_movie =
      library_path_fixture(%{
        type: "movies",
        path: "/tmp/lib_movie_#{System.unique_integer([:positive])}"
      })

    lp_tv =
      library_path_fixture(%{
        type: "series",
        path: "/tmp/lib_tv_#{System.unique_integer([:positive])}"
      })

    {:ok, view, _html} = live(conn, ~p"/import?type=tv")

    assert has_element?(view, "#library-tab-#{lp_tv.id}.tab-active")
    refute has_element?(view, "#library-tab-#{lp_movie.id}.tab-active")
    assert has_element?(view, "input[name='library_path_id'][value='#{lp_tv.id}']")
  end

  test "changing the library tab updates scan and review selection", %{
    conn: conn
  } do
    _lp1 =
      library_path_fixture(%{
        type: "series",
        path: "/tmp/lib_1_#{System.unique_integer([:positive])}"
      })

    lp2 =
      library_path_fixture(%{
        type: "movies",
        path: "/tmp/lib_2_#{System.unique_integer([:positive])}"
      })

    {:ok, view, _html} = live(conn, ~p"/import")

    view |> element("#library-tab-#{lp2.id}") |> render_click()

    assert has_element?(view, "#library-tab-#{lp2.id}.tab-active")
    assert has_element?(view, "input[name='library_path_id'][value='#{lp2.id}']")
  end
end
