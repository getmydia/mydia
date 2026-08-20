defmodule MydiaWeb.AdminLibraryPruneLiveTest do
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
    {"Rick and Morty/Season 02/Rick.and.Morty.S02E03.1080p.BluRay.x265.mp4",
     %{resolution: "1080p", codec: "hevc", bitrate: 2_002_656}},
    {"Rick and Morty/Season 02/Rick.and.Morty.S02E03.360p.WEBRip.x264.mp4",
     %{resolution: "360p", codec: "h264", bitrate: 1_000_000}}
  ]

  # A third copy, so a test can uncheck one duplicate and still have another
  # left to trash. With only two files, unchecking the single loser empties
  # the selection and there is nothing left to assert about.
  @three_files @two_files ++
                 [
                   {"Rick and Morty/Season 02/Rick.and.Morty.S02E03.480p.WEBRip.x264.mp4",
                    %{resolution: "480p", codec: "h264", bitrate: 500_000}}
                 ]

  defp prunable_episode(specs \\ @two_files) do
    show = media_item_fixture(%{type: "tv_show", title: "Rick and Morty", year: 2013})
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
    movie = media_item_fixture(%{type: "movie", title: "Monsters University", year: 2013})
    lp = library_path_fixture(%{type: "movies"})

    for {name, duration} <- [
          {"MU/Monsters University (2013).mkv", 6360.0},
          {"MU/Campus Life.mkv", 280.0}
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

  describe "the prune page" do
    setup %{conn: conn, token: token} do
      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      %{conn: conn}
    end

    test "renders a prunable group with a selectable loser", %{conn: conn} do
      {_show, _episode, files} = prunable_episode()
      loser = Enum.find(files, &(&1.relative_path =~ "360p"))

      {:ok, view, _html} = live(conn, ~p"/admin/config/prune")

      assert has_element?(view, "#prune-loser-#{loser.id}")
    end

    test "renders the admin tab strip with prune as the active tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/config/prune")

      assert has_element?(view, "div[role=tablist]")
      assert has_element?(view, "a.tab-active", "Prune duplicates")
      # Every other admin page's tab must still be reachable from here, or an
      # operator who lands on this page has no way back to the rest of admin.
      assert has_element?(view, "a[href='/admin/config/library-paths']", "Library")
    end

    test "heads its sections with h2 and leaves the page h1 to the admin shell", %{conn: conn} do
      prunable_episode()
      refused_movie()

      {:ok, view, _html} = live(conn, ~p"/admin/config/prune")

      # <.admin_page> already renders the "Configuration" <h1> and the tab
      # strip. Every other /admin/config tab opens its body with an <h2>
      # section header carrying a count badge, and adds no <h1> of its own.
      assert has_element?(view, "h2", "Duplicate Files")
      assert has_element?(view, "h2", "Needs Attention")
      assert has_element?(view, "h2 span.badge-ghost")
      refute has_element?(view, "h1", "Prune")
      refute has_element?(view, "h1", "Duplicate")
    end

    test "renders a refused group without any selectable file", %{conn: conn} do
      movie = refused_movie()

      {:ok, view, _html} = live(conn, ~p"/admin/config/prune")

      assert has_element?(view, "#prune-refusal-#{movie.id}")
      refute has_element?(view, "#prune-refusal-#{movie.id} input[type=checkbox]")
    end

    test "explains a duration mismatch refusal with the actual spread and tolerance",
         %{conn: conn} do
      # refused_movie/0's durations are 6360.0s and 280.0s, a ~95.6% spread
      # against the 2.0% tolerance. The explanation must show both numbers so
      # an operator can see how far apart the files actually were, not just
      # that they disagreed.
      movie = refused_movie()

      {:ok, view, _html} = live(conn, ~p"/admin/config/prune")

      group_html = view |> element("#prune-refusal-#{movie.id}") |> render()

      assert group_html =~ "95.6%"
      assert group_html =~ "2.0%"
    end

    test "every lower-quality duplicate is checked on arrival", %{conn: conn} do
      {_show, _episode, files} = prunable_episode(@three_files)
      keeper = Enum.find(files, &(&1.relative_path =~ "1080p"))
      losers = Enum.reject(files, &(&1.id == keeper.id))

      {:ok, view, _html} = live(conn, ~p"/admin/config/prune")

      for loser <- losers do
        assert has_element?(view, "#prune-loser-#{loser.id}[checked]"),
               "#{loser.relative_path} should be selected without the operator touching it"
      end

      refute has_element?(view, "#prune-loser-#{keeper.id}")
    end

    test "trashes every duplicate from a clean load with no checkbox clicks", %{conn: conn} do
      # This is the one-click path: land on the page, press Trash, confirm.
      # Nothing on the group is touched in between.
      {_show, _episode, files} = prunable_episode(@three_files)
      keeper = Enum.find(files, &(&1.relative_path =~ "1080p"))
      losers = Enum.reject(files, &(&1.id == keeper.id))

      {:ok, view, _html} = live(conn, ~p"/admin/config/prune")

      view |> element("#prune-trash-selected") |> render_click()
      view |> element("#prune-confirm") |> render_click()

      for loser <- losers do
        assert Mydia.Repo.get!(Mydia.Library.MediaFile, loser.id).trashed_at
      end

      refute Mydia.Repo.get!(Mydia.Library.MediaFile, keeper.id).trashed_at
    end

    test "unchecking a duplicate leaves it on disk while the rest are trashed", %{conn: conn} do
      {_show, _episode, files} = prunable_episode(@three_files)
      keeper = Enum.find(files, &(&1.relative_path =~ "1080p"))
      spared = Enum.find(files, &(&1.relative_path =~ "480p"))
      doomed = Enum.find(files, &(&1.relative_path =~ "360p"))

      {:ok, view, _html} = live(conn, ~p"/admin/config/prune")

      view |> element("#prune-loser-#{spared.id}") |> render_click()
      refute has_element?(view, "#prune-loser-#{spared.id}[checked]")

      view |> element("#prune-trash-selected") |> render_click()
      view |> element("#prune-confirm") |> render_click()

      assert Mydia.Repo.get!(Mydia.Library.MediaFile, doomed.id).trashed_at
      refute Mydia.Repo.get!(Mydia.Library.MediaFile, spared.id).trashed_at
      refute Mydia.Repo.get!(Mydia.Library.MediaFile, keeper.id).trashed_at
    end

    test "the group toggle skips the whole group, and pressing it again restores it",
         %{conn: conn} do
      {_show, episode, files} = prunable_episode(@three_files)
      keeper = Enum.find(files, &(&1.relative_path =~ "1080p"))
      losers = Enum.reject(files, &(&1.id == keeper.id))

      {:ok, view, _html} = live(conn, ~p"/admin/config/prune")

      view |> element("#prune-group-toggle-#{episode.id}") |> render_click()

      for loser <- losers do
        refute has_element?(view, "#prune-loser-#{loser.id}[checked]")
      end

      assert has_element?(view, "#prune-trash-selected[disabled]")

      view |> element("#prune-group-toggle-#{episode.id}") |> render_click()

      for loser <- losers do
        assert has_element?(view, "#prune-loser-#{loser.id}[checked]")
      end
    end

    test "the confirmation modal opens on Trash and closes on Cancel without trashing anything",
         %{conn: conn} do
      {_show, _episode, files} = prunable_episode()

      {:ok, view, _html} = live(conn, ~p"/admin/config/prune")

      refute has_element?(view, "#prune-confirm-modal")

      view |> element("#prune-trash-selected") |> render_click()
      assert has_element?(view, "#prune-confirm-modal")

      view |> element("#prune-cancel") |> render_click()
      refute has_element?(view, "#prune-confirm-modal")

      for file <- files do
        refute Mydia.Repo.get!(Mydia.Library.MediaFile, file.id).trashed_at
      end
    end

    test "changing the keeper re-derives the losers and selects the demoted file",
         %{conn: conn} do
      {_show, _episode, files} = prunable_episode()
      low = Enum.find(files, &(&1.relative_path =~ "360p"))
      high = Enum.find(files, &(&1.relative_path =~ "1080p"))

      {:ok, view, _html} = live(conn, ~p"/admin/config/prune")

      view |> element("#prune-keeper-#{low.id}") |> render_click()

      # The file that stopped being the keeper has to come back selected, or
      # overriding the keeper would silently leave the operator with an empty
      # selection and a disabled Trash button.
      assert has_element?(view, "#prune-loser-#{high.id}[checked]")
      refute has_element?(view, "#prune-loser-#{low.id}")
    end

    test "confirming after overriding the keeper trashes the operator's chosen file, not the ranked keeper",
         %{conn: conn} do
      {_show, _episode, files} = prunable_episode()
      ranked_keeper = Enum.find(files, &(&1.relative_path =~ "1080p"))
      overridden_keeper = Enum.find(files, &(&1.relative_path =~ "360p"))

      {:ok, view, _html} = live(conn, ~p"/admin/config/prune")

      # Override the keeper to the lower-quality file. The higher-quality
      # (ranked) file becomes the loser and is selected by default. If
      # `confirm_prune` ever calls `Prune.execute/2` instead of `execute/3`
      # with the keepers map, the ranked keeper gets silently re-derived as
      # 1080p again and this trashing gets aborted as `:would_leave_no_file`
      # instead of applied.
      view |> element("#prune-keeper-#{overridden_keeper.id}") |> render_click()
      view |> element("#prune-trash-selected") |> render_click()
      view |> element("#prune-confirm") |> render_click()

      assert Mydia.Repo.get!(Mydia.Library.MediaFile, ranked_keeper.id).trashed_at
      refute Mydia.Repo.get!(Mydia.Library.MediaFile, overridden_keeper.id).trashed_at
    end

    test "the keeper radio and loser checkbox are independently and unambiguously operable",
         %{conn: conn} do
      {_show, episode, files} = prunable_episode()
      keeper = Enum.find(files, &(&1.relative_path =~ "1080p"))
      loser = Enum.find(files, &(&1.relative_path =~ "360p"))

      {:ok, view, _html} = live(conn, ~p"/admin/config/prune")

      group_html = view |> element("#prune-group-#{episode.id}") |> render()

      # The keeper radio and the loser checkbox must not be governed by one
      # shared <label>: a click anywhere in the row would otherwise only
      # ever activate the first labelable descendant (the keeper radio),
      # silently reassigning the keeper when the operator meant to toggle
      # the trash checkbox.
      refute group_html =~ "<label"

      keeper_match =
        Regex.run(~r/id="prune-keeper-#{keeper.id}"[^>]*aria-label="([^"]*)"/, group_html)

      loser_match =
        Regex.run(~r/id="prune-loser-#{loser.id}"[^>]*aria-label="([^"]*)"/, group_html)

      assert [_, keeper_label] = keeper_match
      assert [_, loser_label] = loser_match
      assert keeper_label != loser_label
    end
  end
end
