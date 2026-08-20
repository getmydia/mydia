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

  defp prunable_episode do
    show = media_item_fixture(%{type: "tv_show", title: "Rick and Morty", year: 2013})
    episode = episode_fixture(%{media_item_id: show.id, season_number: 2, episode_number: 3})
    lp = library_path_fixture(%{type: "series"})

    files =
      for {name, attrs} <- [
            {"Rick and Morty/Season 02/Rick.and.Morty.S02E03.1080p.BluRay.x265.mp4",
             %{resolution: "1080p", codec: "hevc", bitrate: 2_002_656}},
            {"Rick and Morty/Season 02/Rick.and.Morty.S02E03.360p.WEBRip.x264.mp4",
             %{resolution: "360p", codec: "h264", bitrate: 1_000_000}}
          ] do
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

      {:ok, view, _html} = live(conn, ~p"/admin/library/prune")

      assert has_element?(view, "#prune-loser-#{loser.id}")
    end

    test "renders the admin tab strip with prune as the active tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/library/prune")

      assert has_element?(view, "div[role=tablist]")
      assert has_element?(view, "a.tab-active", "Prune duplicates")
      # Every other admin page's tab must still be reachable from here, or an
      # operator who lands on this page has no way back to the rest of admin.
      assert has_element?(view, "a[href='/admin/config/library-paths']", "Library")
    end

    test "renders a refused group without any selectable file", %{conn: conn} do
      movie = refused_movie()

      {:ok, view, _html} = live(conn, ~p"/admin/library/prune")

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

      {:ok, view, _html} = live(conn, ~p"/admin/library/prune")

      group_html = view |> element("#prune-refusal-#{movie.id}") |> render()

      assert group_html =~ "95.6%"
      assert group_html =~ "2.0%"
    end

    test "trashes the selected loser on confirm", %{conn: conn} do
      {_show, _episode, files} = prunable_episode()
      loser = Enum.find(files, &(&1.relative_path =~ "360p"))
      keeper = Enum.find(files, &(&1.relative_path =~ "1080p"))

      {:ok, view, _html} = live(conn, ~p"/admin/library/prune")

      view |> element("#prune-loser-#{loser.id}") |> render_click()
      view |> element("#prune-confirm") |> render_click()

      assert Mydia.Repo.get!(Mydia.Library.MediaFile, loser.id).trashed_at
      refute Mydia.Repo.get!(Mydia.Library.MediaFile, keeper.id).trashed_at
    end

    test "changing the keeper re-derives the losers", %{conn: conn} do
      {_show, _episode, files} = prunable_episode()
      low = Enum.find(files, &(&1.relative_path =~ "360p"))
      high = Enum.find(files, &(&1.relative_path =~ "1080p"))

      {:ok, view, _html} = live(conn, ~p"/admin/library/prune")

      view |> element("#prune-keeper-#{low.id}") |> render_click()

      assert has_element?(view, "#prune-loser-#{high.id}")
      refute has_element?(view, "#prune-loser-#{low.id}")
    end

    test "confirming after overriding the keeper trashes the operator's chosen file, not the ranked keeper",
         %{conn: conn} do
      {_show, _episode, files} = prunable_episode()
      ranked_keeper = Enum.find(files, &(&1.relative_path =~ "1080p"))
      overridden_keeper = Enum.find(files, &(&1.relative_path =~ "360p"))

      {:ok, view, _html} = live(conn, ~p"/admin/library/prune")

      # Override the keeper to the lower-quality file, then select the
      # higher-quality (ranked) file for trashing. If `confirm` ever calls
      # `Prune.execute/2` instead of `execute/3` with the keepers map, the
      # ranked keeper gets silently re-derived as 1080p again and this
      # trashing gets aborted as `:would_leave_no_file` instead of applied.
      view |> element("#prune-keeper-#{overridden_keeper.id}") |> render_click()
      view |> element("#prune-loser-#{ranked_keeper.id}") |> render_click()
      view |> element("#prune-confirm") |> render_click()

      assert Mydia.Repo.get!(Mydia.Library.MediaFile, ranked_keeper.id).trashed_at
      refute Mydia.Repo.get!(Mydia.Library.MediaFile, overridden_keeper.id).trashed_at
    end

    test "the keeper radio and loser checkbox are independently and unambiguously operable",
         %{conn: conn} do
      {_show, episode, files} = prunable_episode()
      keeper = Enum.find(files, &(&1.relative_path =~ "1080p"))
      loser = Enum.find(files, &(&1.relative_path =~ "360p"))

      {:ok, view, _html} = live(conn, ~p"/admin/library/prune")

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
