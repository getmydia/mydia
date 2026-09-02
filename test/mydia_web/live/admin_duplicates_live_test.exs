defmodule MydiaWeb.AdminDuplicatesLiveTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Accounts

  # Mirrors test/mydia_web/live/admin_quality_profiles_live_test.exs, which is
  # the canonical admin LiveView setup in this project.
  setup do
    unique_id = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.create_user(%{
        email: "admin_#{unique_id}@example.com",
        username: "admin_#{unique_id}",
        password_hash: "$2b$12$test",
        role: "admin"
      })

    {:ok, token, _claims} = Mydia.Auth.Guardian.encode_and_sign(user)

    %{user: user, token: token}
  end

  @two_files [
    {"Harbor Lights/Season 02/Harbor.Lights.S02E03.1080p.BluRay.x265.mp4",
     %{resolution: "1080p", codec: "hevc", bitrate: 2_002_656}},
    {"Harbor Lights/Season 02/Harbor.Lights.S02E03.360p.WEBRip.x264.mp4",
     %{resolution: "360p", codec: "h264", bitrate: 1_000_000}}
  ]

  # A third copy, so a test can keep one duplicate and still have another
  # left to trash. With only two files, keeping the single loser empties
  # the selection and there is nothing left to assert about.
  @three_files @two_files ++
                 [
                   {"Harbor Lights/Season 02/Harbor.Lights.S02E03.480p.WEBRip.x264.mp4",
                    %{resolution: "480p", codec: "h264", bitrate: 500_000}}
                 ]

  defp duplicated_episode(specs \\ @two_files) do
    show = media_item_fixture(%{type: "tv_show", title: "Harbor Lights", year: 2013})
    episode = episode_fixture(%{media_item_id: show.id, season_number: 2, episode_number: 3})
    lp = library_path_fixture(%{type: "series"})

    files =
      for {name, attrs} <- specs do
        attrs
        |> Map.merge(%{
          episode_id: episode.id,
          library_path_id: lp.id,
          relative_path: name,
          metadata: %{"container" => "mp4", "duration" => 1320.0}
        })
        |> media_file_fixture()
      end

    {show, episode, files}
  end

  defp refused_movie do
    movie = media_item_fixture(%{type: "movie", title: "Tidepool Academy", year: 2013})
    lp = library_path_fixture(%{type: "movies"})

    for {name, duration} <- [
          {"TA/Tidepool Academy (2013).mkv", 6360.0},
          {"TA/Orientation Week.mkv", 280.0}
        ] do
      media_file_fixture(%{
        media_item_id: movie.id,
        library_path_id: lp.id,
        relative_path: name,
        metadata: %{"container" => "mkv", "duration" => duration}
      })
    end

    movie
  end

  defp trashed?(file),
    do: not is_nil(Mydia.Repo.get!(Mydia.Library.MediaFile, file.id).trashed_at)

  describe "the duplicates page" do
    setup %{conn: conn, token: token} do
      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      %{conn: conn}
    end

    test "gives every file one Keep/Trash control and nothing else", %{conn: conn} do
      # The point of this page's control is that a file's fate is decided in
      # exactly one place. A second widget per row (the keeper radio and the
      # red checkbox this replaced) leaves an operator guessing which one
      # governs. Both options are named on screen so neither has to be
      # inferred from a colour.
      {_show, episode, files} = duplicated_episode()

      {:ok, view, _html} = live(conn, ~p"/admin/config/duplicates")

      group_html = view |> element("#duplicates-group-#{episode.id}") |> render()

      for file <- files do
        assert has_element?(view, "#duplicates-keep-#{file.id}[aria-label='Keep']")
        assert has_element?(view, "#duplicates-trash-#{file.id}[aria-label='Trash']")
      end

      # Two inputs per file, both in the same radiogroup, and no third control.
      assert group_html |> String.split("<input") |> length() == length(files) * 2 + 1
      refute group_html =~ "type=\"checkbox\""
    end

    test "renders the admin tab strip with duplicates as the active tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/config/duplicates")

      assert has_element?(view, "div[role=tablist]")
      assert has_element?(view, "a.tab-active", "Duplicates")
      # Every other admin page's tab must still be reachable from here, or an
      # operator who lands on this page has no way back to the rest of admin.
      assert has_element?(view, "a[href='/admin/config/library-paths']", "Library")
    end

    test "heads its sections with h2 and leaves the page h1 to the admin shell", %{conn: conn} do
      duplicated_episode()
      refused_movie()

      {:ok, view, _html} = live(conn, ~p"/admin/config/duplicates")

      # <.admin_page> already renders the "Configuration" <h1> and the tab
      # strip. Every other /admin/config tab opens its body with an <h2>
      # section header carrying a count badge, and adds no <h1> of its own.
      assert has_element?(view, "h2", "Duplicates")
      assert has_element?(view, "h2", "Needs Attention")
      assert has_element?(view, "h2 span.badge-ghost")
      refute has_element?(view, "h1", "Duplicate")
    end

    test "renders a refused group without any Keep or Trash control", %{conn: conn} do
      movie = refused_movie()

      {:ok, view, _html} = live(conn, ~p"/admin/config/duplicates")

      assert has_element?(view, "#duplicates-refusal-#{movie.id}")
      refute has_element?(view, "#duplicates-refusal-#{movie.id} input")
    end

    test "explains a duration mismatch refusal with the actual spread and tolerance",
         %{conn: conn} do
      # refused_movie/0's durations are 6360.0s and 280.0s, a ~95.6% spread
      # against the 2.0% tolerance. The explanation must show both numbers so
      # an operator can see how far apart the files actually were, not just
      # that they disagreed.
      movie = refused_movie()

      {:ok, view, _html} = live(conn, ~p"/admin/config/duplicates")

      group_html = view |> element("#duplicates-refusal-#{movie.id}") |> render()

      assert group_html =~ "95.6%"
      assert group_html =~ "2.0%"
    end

    test "the best copy is listed first, on Keep, with every duplicate on Trash",
         %{conn: conn} do
      {_show, _episode, files} = duplicated_episode(@three_files)
      keeper = Enum.find(files, &(&1.relative_path =~ "1080p"))
      losers = Enum.reject(files, &(&1.id == keeper.id))

      {:ok, view, _html} = live(conn, ~p"/admin/config/duplicates")

      assert has_element?(view, "#duplicates-keep-#{keeper.id}[checked]")
      refute has_element?(view, "#duplicates-trash-#{keeper.id}[checked]")

      for loser <- losers do
        assert has_element?(view, "#duplicates-trash-#{loser.id}[checked]"),
               "#{loser.relative_path} should be on Trash without the operator touching it"
      end
    end

    test "trashes every duplicate from a clean load with no row clicks", %{conn: conn} do
      # This is the one-click path: land on the page, press Trash, confirm.
      # Nothing on the group is touched in between.
      {_show, _episode, files} = duplicated_episode(@three_files)
      keeper = Enum.find(files, &(&1.relative_path =~ "1080p"))
      losers = Enum.reject(files, &(&1.id == keeper.id))

      {:ok, view, _html} = live(conn, ~p"/admin/config/duplicates")

      view |> element("#duplicates-trash-selected") |> render_click()
      view |> element("#duplicates-confirm") |> render_click()

      for loser <- losers, do: assert(trashed?(loser))
      refute trashed?(keeper)
    end

    test "setting a duplicate to Keep leaves it on disk while the rest are trashed",
         %{conn: conn} do
      {_show, _episode, files} = duplicated_episode(@three_files)
      keeper = Enum.find(files, &(&1.relative_path =~ "1080p"))
      spared = Enum.find(files, &(&1.relative_path =~ "480p"))
      doomed = Enum.find(files, &(&1.relative_path =~ "360p"))

      {:ok, view, _html} = live(conn, ~p"/admin/config/duplicates")

      view |> element("#duplicates-keep-#{spared.id}") |> render_click()
      assert has_element?(view, "#duplicates-keep-#{spared.id}[checked]")
      refute has_element?(view, "#duplicates-trash-#{spared.id}[checked]")

      view |> element("#duplicates-trash-selected") |> render_click()
      view |> element("#duplicates-confirm") |> render_click()

      assert trashed?(doomed)
      refute trashed?(spared)
      refute trashed?(keeper)
    end

    test "the marking toggle spares the whole group and puts it back", %{conn: conn} do
      {_show, episode, files} = duplicated_episode(@three_files)
      keeper = Enum.find(files, &(&1.relative_path =~ "1080p"))
      losers = Enum.reject(files, &(&1.id == keeper.id))

      {:ok, view, _html} = live(conn, ~p"/admin/config/duplicates")

      view |> element("#duplicates-group-mark-#{episode.id}") |> render_click()

      for loser <- losers do
        assert has_element?(view, "#duplicates-keep-#{loser.id}[checked]")
      end

      assert has_element?(view, "#duplicates-trash-selected[disabled]")
      # Nothing was trashed: this control only marks.
      for file <- files, do: refute(trashed?(file))

      view |> element("#duplicates-group-mark-#{episode.id}") |> render_click()

      for loser <- losers do
        assert has_element?(view, "#duplicates-trash-#{loser.id}[checked]")
      end
    end

    test "the group trash button trashes only its own group", %{conn: conn} do
      {_show_a, episode_a, files_a} = duplicated_episode(@three_files)
      {_show_b, _episode_b, files_b} = duplicated_episode(@three_files)
      keeper_a = Enum.find(files_a, &(&1.relative_path =~ "1080p"))
      losers_a = Enum.reject(files_a, &(&1.id == keeper_a.id))

      {:ok, view, _html} = live(conn, ~p"/admin/config/duplicates")

      view |> element("#duplicates-group-trash-#{episode_a.id}") |> render_click()

      for loser <- losers_a, do: assert(trashed?(loser))
      refute trashed?(keeper_a)
      for file <- files_b, do: refute(trashed?(file))
    end

    test "the group trash button spares a file set to Keep", %{conn: conn} do
      {_show, episode, files} = duplicated_episode(@three_files)
      keeper = Enum.find(files, &(&1.relative_path =~ "1080p"))
      spared = Enum.find(files, &(&1.relative_path =~ "480p"))
      doomed = Enum.find(files, &(&1.relative_path =~ "360p"))

      {:ok, view, _html} = live(conn, ~p"/admin/config/duplicates")

      view |> element("#duplicates-keep-#{spared.id}") |> render_click()
      view |> element("#duplicates-group-trash-#{episode.id}") |> render_click()

      assert trashed?(doomed)
      refute trashed?(spared)
      refute trashed?(keeper)
    end

    test "the group trash button honours a keeper override", %{conn: conn} do
      # Trashing the best copy promotes the next one. The group button has to
      # hand execute/3 that override, or the ranked keeper is re-derived as the
      # 1080p file and the run is aborted as :would_leave_no_file.
      {_show, episode, files} = duplicated_episode()
      high = Enum.find(files, &(&1.relative_path =~ "1080p"))
      low = Enum.find(files, &(&1.relative_path =~ "360p"))

      {:ok, view, _html} = live(conn, ~p"/admin/config/duplicates")

      view |> element("#duplicates-trash-#{high.id}") |> render_click()
      view |> element("#duplicates-group-trash-#{episode.id}") |> render_click()

      assert trashed?(high)
      refute trashed?(low)
    end

    test "a fully pruned group leaves the page entirely", %{conn: conn} do
      # Grouping.multi_file_ids/1 selects with `having count > 1` over untrashed
      # rows, so a group down to one file is no longer a group. It must not
      # reappear under Needs Attention as a :nothing_to_prune refusal.
      {_show, episode, _files} = duplicated_episode()

      {:ok, view, _html} = live(conn, ~p"/admin/config/duplicates")
      assert has_element?(view, "#duplicates-group-#{episode.id}")

      view |> element("#duplicates-group-trash-#{episode.id}") |> render_click()

      refute has_element?(view, "#duplicates-group-#{episode.id}")
      refute has_element?(view, "#duplicates-refusal-#{episode.id}")
    end

    test "the group trash button is disabled when the group has nothing marked",
         %{conn: conn} do
      {_show, episode, _files} = duplicated_episode(@three_files)

      {:ok, view, _html} = live(conn, ~p"/admin/config/duplicates")

      refute has_element?(view, "#duplicates-group-trash-#{episode.id}[disabled]")

      view |> element("#duplicates-group-mark-#{episode.id}") |> render_click()

      assert has_element?(view, "#duplicates-group-trash-#{episode.id}[disabled]")
    end

    test "the confirmation modal opens on Trash and closes on Cancel without trashing anything",
         %{conn: conn} do
      {_show, _episode, files} = duplicated_episode()

      {:ok, view, _html} = live(conn, ~p"/admin/config/duplicates")

      refute has_element?(view, "#duplicates-confirm-modal")

      view |> element("#duplicates-trash-selected") |> render_click()
      assert has_element?(view, "#duplicates-confirm-modal")

      view |> element("#duplicates-cancel") |> render_click()
      refute has_element?(view, "#duplicates-confirm-modal")

      for file <- files, do: refute(trashed?(file))
    end

    test "a Trash event pairing one group's subject with another group's file changes nothing",
         %{conn: conn} do
      # The dangerous direction of the same asymmetry: an unvalidated
      # `trash_file` would drop the named file from the Keep set no matter
      # which group it belongs to, putting a copy the operator spared back on
      # Trash under a group they were not looking at.
      {_show_a, episode_a, _files_a} = duplicated_episode(@three_files)
      {_show_b, _episode_b, files_b} = duplicated_episode(@three_files)
      keeper_b = Enum.find(files_b, &(&1.relative_path =~ "1080p"))
      spared_b = Enum.find(files_b, &(&1.relative_path =~ "480p"))

      {:ok, view, _html} = live(conn, ~p"/admin/config/duplicates")

      view |> element("#duplicates-keep-#{spared_b.id}") |> render_click()
      assert has_element?(view, "#duplicates-keep-#{spared_b.id}[checked]")

      render_click(view, "trash_file", %{"subject" => episode_a.id, "file" => spared_b.id})

      assert has_element?(view, "#duplicates-keep-#{spared_b.id}[checked]")
      refute has_element?(view, "#duplicates-trash-#{spared_b.id}[checked]")
      refute has_element?(view, "#duplicates-trash-#{keeper_b.id}[checked]")
    end

    test "a Keep event naming a file outside the group changes nothing", %{conn: conn} do
      # Both row handlers resolve the decision before trusting the id the
      # client sent. Without that, keep_file would bank any id at all in the
      # Keep set, where it would sit for the life of the socket.
      {_show, episode, files} = duplicated_episode(@three_files)
      keeper = Enum.find(files, &(&1.relative_path =~ "1080p"))
      losers = Enum.reject(files, &(&1.id == keeper.id))

      {:ok, view, _html} = live(conn, ~p"/admin/config/duplicates")

      render_click(view, "keep_file", %{"subject" => episode.id, "file" => Ecto.UUID.generate()})
      render_click(view, "keep_file", %{"subject" => Ecto.UUID.generate(), "file" => keeper.id})

      for loser <- losers do
        assert has_element?(view, "#duplicates-trash-#{loser.id}[checked]")
      end

      refute has_element?(view, "#duplicates-trash-selected[disabled]")
    end

    test "a file set to Keep is still on Keep after the run that trashed the others",
         %{conn: conn} do
      # The group still holds two files afterwards (the keeper and the spared
      # copy) and stays eligible, so it re-plans with the spared file as a
      # loser. If the Keep set were cleared on confirm, that file would come
      # back on Trash and the page would offer to trash the very copy the
      # operator just spared, one click away.
      {_show, _episode, files} = duplicated_episode(@three_files)
      keeper = Enum.find(files, &(&1.relative_path =~ "1080p"))
      spared = Enum.find(files, &(&1.relative_path =~ "480p"))
      doomed = Enum.find(files, &(&1.relative_path =~ "360p"))

      {:ok, view, _html} = live(conn, ~p"/admin/config/duplicates")

      view |> element("#duplicates-keep-#{spared.id}") |> render_click()
      view |> element("#duplicates-trash-selected") |> render_click()
      view |> element("#duplicates-confirm") |> render_click()

      assert trashed?(doomed)
      refute trashed?(spared)
      refute trashed?(keeper)

      # The group is still on the page, and the spared file is still on Keep
      # rather than queued up again.
      assert has_element?(view, "#duplicates-keep-#{spared.id}[checked]")
      refute has_element?(view, "#duplicates-trash-#{spared.id}[checked]")
      assert has_element?(view, "#duplicates-trash-selected[disabled]")
    end

    test "trashing the best copy promotes the next one instead of emptying the item",
         %{conn: conn} do
      # There is no separate keeper control any more, so Trash on the top row
      # has to do the promotion itself. If it did not, the operator would
      # either lose every copy or find their click silently ignored.
      {_show, _episode, files} = duplicated_episode()
      high = Enum.find(files, &(&1.relative_path =~ "1080p"))
      low = Enum.find(files, &(&1.relative_path =~ "360p"))

      {:ok, view, _html} = live(conn, ~p"/admin/config/duplicates")

      view |> element("#duplicates-trash-#{high.id}") |> render_click()

      assert has_element?(view, "#duplicates-trash-#{high.id}[checked]")
      assert has_element?(view, "#duplicates-keep-#{low.id}[checked]")
    end

    test "confirming after trashing the best copy trashes it, not the one that replaced it",
         %{conn: conn} do
      # `confirm_trash` has to hand `Prune.execute/3` the keeper override the
      # promotion implied. Without it the ranked keeper is silently re-derived
      # as the 1080p file again and this trashing is aborted as
      # `:would_leave_no_file` rather than applied.
      {_show, _episode, files} = duplicated_episode()
      high = Enum.find(files, &(&1.relative_path =~ "1080p"))
      low = Enum.find(files, &(&1.relative_path =~ "360p"))

      {:ok, view, _html} = live(conn, ~p"/admin/config/duplicates")

      view |> element("#duplicates-trash-#{high.id}") |> render_click()
      view |> element("#duplicates-trash-selected") |> render_click()
      view |> element("#duplicates-confirm") |> render_click()

      assert trashed?(high)
      refute trashed?(low)
    end

    test "trashing the best copy promotes a copy the operator already set to Keep",
         %{conn: conn} do
      # The 480p file is worse than the 360p one on bitrate, so the ranker
      # would promote 360p on its own. An explicit Keep outranks that: the
      # operator has already said which copy they want to survive.
      {_show, _episode, files} = duplicated_episode(@three_files)
      high = Enum.find(files, &(&1.relative_path =~ "1080p"))
      mid = Enum.find(files, &(&1.relative_path =~ "360p"))
      spared = Enum.find(files, &(&1.relative_path =~ "480p"))

      {:ok, view, _html} = live(conn, ~p"/admin/config/duplicates")

      view |> element("#duplicates-keep-#{spared.id}") |> render_click()
      view |> element("#duplicates-trash-#{high.id}") |> render_click()

      assert has_element?(view, "#duplicates-keep-#{spared.id}[checked]")
      assert has_element?(view, "#duplicates-trash-#{high.id}[checked]")
      assert has_element?(view, "#duplicates-trash-#{mid.id}[checked]")

      view |> element("#duplicates-trash-selected") |> render_click()
      view |> element("#duplicates-confirm") |> render_click()

      assert trashed?(high)
      assert trashed?(mid)
      refute trashed?(spared)
    end

    test "every group always keeps a file no matter how many rows are set to Trash",
         %{conn: conn} do
      # Clicking Trash on every row in turn must never leave the item with
      # nothing. Each click on the current top row promotes the next one.
      {_show, _episode, files} = duplicated_episode(@three_files)

      {:ok, view, _html} = live(conn, ~p"/admin/config/duplicates")

      for file <- files do
        view |> element("#duplicates-trash-#{file.id}") |> render_click()
      end

      kept = Enum.count(files, &has_element?(view, "#duplicates-keep-#{&1.id}[checked]"))
      assert kept == 1

      view |> element("#duplicates-trash-selected") |> render_click()
      view |> element("#duplicates-confirm") |> render_click()

      assert Enum.count(files, &trashed?/1) == length(files) - 1
    end

    test "a group run raises an undo toast naming the item", %{conn: conn} do
      {_show, episode, _files} = duplicated_episode()

      {:ok, view, _html} = live(conn, ~p"/admin/config/duplicates")
      refute has_element?(view, "#duplicates-undo-toast")

      view |> element("#duplicates-group-trash-#{episode.id}") |> render_click()

      assert has_element?(view, "#duplicates-undo-toast")
      assert render(view) =~ "Harbor Lights S02E03"
    end

    test "Undo restores the files and puts them back on Keep, not Trash", %{conn: conn} do
      # A restored file is a loser of an eligible group again, and losers
      # default to Trash. Without putting them on Keep the page would offer to
      # trash the very copies the operator just rescued.
      {_show, episode, files} = duplicated_episode()
      keeper = Enum.find(files, &(&1.relative_path =~ "1080p"))
      loser = Enum.find(files, &(&1.relative_path =~ "360p"))

      {:ok, view, _html} = live(conn, ~p"/admin/config/duplicates")

      view |> element("#duplicates-group-trash-#{episode.id}") |> render_click()
      assert trashed?(loser)

      view |> element("#duplicates-undo") |> render_click()

      refute trashed?(loser)
      refute trashed?(keeper)
      assert has_element?(view, "#duplicates-group-#{episode.id}")
      assert has_element?(view, "#duplicates-keep-#{loser.id}[checked]")
      refute has_element?(view, "#duplicates-trash-#{loser.id}[checked]")
      refute has_element?(view, "#duplicates-undo-toast")
    end

    test "dismissing the toast leaves the files trashed", %{conn: conn} do
      {_show, episode, files} = duplicated_episode()
      loser = Enum.find(files, &(&1.relative_path =~ "360p"))

      {:ok, view, _html} = live(conn, ~p"/admin/config/duplicates")

      view |> element("#duplicates-group-trash-#{episode.id}") |> render_click()
      view |> element("#duplicates-undo-dismiss") |> render_click()

      refute has_element?(view, "#duplicates-undo-toast")
      assert trashed?(loser)
    end

    test "a second run replaces the first toast rather than stacking", %{conn: conn} do
      # Both fixtures carry the same title, so the toast label cannot tell the
      # groups apart. The counts can: group A trashes one file, group B two.
      # The sharp assertion is what Undo reaches afterwards. If :last_run
      # accumulated instead of being replaced, A's file would come back too.
      {_show_a, episode_a, files_a} = duplicated_episode()
      {_show_b, episode_b, files_b} = duplicated_episode(@three_files)
      loser_a = Enum.find(files_a, &(&1.relative_path =~ "360p"))
      keeper_b = Enum.find(files_b, &(&1.relative_path =~ "1080p"))
      losers_b = Enum.reject(files_b, &(&1.id == keeper_b.id))

      {:ok, view, _html} = live(conn, ~p"/admin/config/duplicates")

      view |> element("#duplicates-group-trash-#{episode_a.id}") |> render_click()
      view |> element("#duplicates-group-trash-#{episode_b.id}") |> render_click()

      # The toast now describes the second run, not the first.
      assert render(view) =~ "Trashed 2 files"

      view |> element("#duplicates-undo") |> render_click()

      for loser <- losers_b, do: refute(trashed?(loser))
      assert trashed?(loser_a), "undo reached the first run's files, so :last_run accumulated"
    end

    test "the page-header run raises the across-items toast", %{conn: conn} do
      duplicated_episode()
      duplicated_episode()

      {:ok, view, _html} = live(conn, ~p"/admin/config/duplicates")

      view |> element("#duplicates-trash-selected") |> render_click()
      view |> element("#duplicates-confirm") |> render_click()

      assert has_element?(view, "#duplicates-undo-toast")
      assert render(view) =~ "2 items"
    end
  end
end
