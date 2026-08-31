defmodule MydiaWeb.ImportMediaRunControlTest do
  use MydiaWeb.ConnCase, async: false
  # Required for assert_enqueued/1. Oban runs testing: :manual in this app, so
  # jobs are inserted but never executed by the test run.
  use Oban.Testing, repo: Mydia.Repo

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures
  import Mydia.MetadataStub
  import Mydia.SettingsFixtures

  alias Mydia.ImportCandidates
  alias Mydia.Library
  alias Mydia.Library.{ImportCandidate, ImportCandidateGroup, MediaFile}
  alias Mydia.Repo

  # "import all accepts every provider-matched result..." promotes a
  # candidate with no locally pre-existing media item (the "uncertain" case),
  # which makes CandidatePromotion enrich through a live provider fetch. The
  # stub keeps that fetch on loopback instead of the real relay -- the test
  # sandbox refuses real outbound HTTP outright.
  setup :setup_metadata_stub

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

    candidate =
      import_candidate_fixture(%{
        library_path_id: lp.id,
        provider_type: "tmdb",
        provider_id: "603",
        title: "The Matrix",
        confidence: 0.95
      })

    dom_id =
      ImportCandidateGroup.dom_id(%ImportCandidateGroup{
        id: candidate.anchor_key,
        anchor_key: candidate.anchor_key,
        library_path_id: lp.id,
        file_count: 1
      })

    refute has_element?(view, "#group-#{dom_id}")

    {:ok, finished} =
      Library.update_import_run(run, %{status: :done, phase: :finished, files_matched: 1})

    send(view.pid, {:import_run_progress, finished})

    assert has_element?(view, "#group-#{dom_id}")
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
    import_candidate_fixture(%{
      library_path_id: lp.id,
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
    candidate =
      import_candidate_fixture(%{
        library_path_id: lp.id,
        provider_type: "tmdb",
        provider_id: "603",
        title: "The Matrix",
        confidence: 0.95
      })

    group = ImportCandidates.get_group(lp.id, candidate.anchor_key)

    {:ok, run} =
      Library.create_import_run(%{library_path_id: lp.id, user_id: user.id, mode: :review})

    {:ok, _} = Library.update_import_run(run, %{status: :done, phase: :finished})

    {:ok, view, _html} = live(conn, ~p"/import?library_path_id=#{lp.id}")

    assert has_element?(view, "#group-#{ImportCandidateGroup.dom_id(group)}")
    assert has_element?(view, "#review-section #clear-scan-results")
    refute has_element?(view, "#start-run-form #clear-scan-results")

    html =
      view
      |> element("#clear-scan-results")
      |> render_click()

    refute has_element?(view, "#run-outcome")
    refute has_element?(view, "#group-#{ImportCandidateGroup.dom_id(group)}")
    assert has_element?(view, "#no-groups", "Nothing to review")
    refute Library.last_import_run(lp.id)

    # The point of clearing: the cached verdict goes too, so the next scan
    # re-matches this file instead of rebuilding the same group from it.
    refute Repo.get(ImportCandidate, candidate.id)
    assert html =~ "Dismissed decisions are preserved"
  end

  test "import all accepts every provider-matched result only for the selected library", %{
    conn: conn,
    library_path: selected
  } do
    confident_movie = media_item_fixture(%{type: "movie", tmdb_id: 9001})

    confident =
      import_candidate_fixture(%{
        library_path_id: selected.id,
        anchor_key: "confident",
        media_type: "movie",
        provider_type: "tmdb",
        provider_id: to_string(confident_movie.tmdb_id),
        title: confident_movie.title,
        year: confident_movie.year,
        confidence: 0.99,
        parsed_info: %{"type" => "movie"}
      })

    uncertain =
      import_candidate_fixture(%{
        library_path_id: selected.id,
        anchor_key: "uncertain",
        media_type: "movie",
        provider_type: "tmdb",
        provider_id: "9002",
        confidence: 0.55,
        parsed_info: %{"type" => "movie"}
      })

    unmatched =
      import_candidate_fixture(%{
        library_path_id: selected.id,
        anchor_key: "unmatched",
        media_type: "movie",
        parsed_info: %{"type" => "movie"}
      })

    local =
      import_candidate_fixture(%{
        library_path_id: selected.id,
        anchor_key: "local",
        provider_type: "local",
        provider_id: "local-item"
      })

    other_library = library_path_fixture(%{type: "movies"})
    other_movie = media_item_fixture(%{type: "movie", tmdb_id: 9003})

    other =
      import_candidate_fixture(%{
        library_path_id: other_library.id,
        anchor_key: "other library",
        media_type: "movie",
        provider_type: "tmdb",
        provider_id: to_string(other_movie.tmdb_id),
        confidence: 0.99,
        parsed_info: %{"type" => "movie"}
      })

    {:ok, view, _html} = live(conn, ~p"/import?library_path_id=#{selected.id}")

    assert has_element?(view, "#review-actions #import-all-results")
    assert has_element?(view, "#review-actions #clear-scan-results")

    view
    |> element("#import-all-results")
    |> render_click()

    refute Repo.get(ImportCandidate, confident.id)
    refute Repo.get(ImportCandidate, uncertain.id)
    assert Repo.get(ImportCandidate, unmatched.id)
    assert Repo.get(ImportCandidate, local.id)
    assert Repo.get(ImportCandidate, other.id)

    assert Repo.exists?(from(f in MediaFile, where: f.media_item_id == ^confident_movie.id))
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
    import_candidate_fixture(%{
      library_path_id: lp.id,
      provider_type: "tmdb",
      provider_id: "603",
      title: "The Matrix",
      confidence: 0.95
    })

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
