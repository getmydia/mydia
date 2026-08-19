defmodule MydiaWeb.MediaLive.Show.EpisodeChunkingTest do
  # async: false — connected LiveView tests hit the Postgres non-shared
  # sandbox, which hides test rows from the mount process.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Mydia.Media.Episode
  alias MydiaWeb.MediaLive.Show.Helpers

  defp episodes(range) do
    for n <- range, do: %Episode{season_number: 1, episode_number: n}
  end

  describe "episode_chunks/1" do
    test "returns a single unlabelled chunk at or below the threshold" do
      assert [{nil, eps}] = Helpers.episode_chunks(episodes(1..50))
      assert length(eps) == 50
    end

    test "returns a single unlabelled chunk for an empty season" do
      assert [{nil, []}] = Helpers.episode_chunks([])
    end

    test "splits a 170-episode season into labelled chunks of 50" do
      chunks = Helpers.episode_chunks(episodes(1..170))

      assert Enum.map(chunks, &elem(&1, 0)) == ["151-170", "101-150", "51-100", "1-50"]
      assert Enum.map(chunks, fn {_label, eps} -> length(eps) end) == [20, 50, 50, 50]
    end

    test "orders chunks and their episodes newest first" do
      [{_label, first_chunk} | _] = Helpers.episode_chunks(episodes(1..170))

      assert Enum.map(first_chunk, & &1.episode_number) == Enum.to_list(170..151//-1)
    end

    test "labels chunks by episode number rather than position" do
      chunks = Helpers.episode_chunks(episodes(101..270))

      assert Enum.map(chunks, &elem(&1, 0)) == ["251-270", "201-250", "151-200", "101-150"]
    end

    test "labels a partial leading chunk from the episodes it holds, not the grid" do
      # 25..100 fills the second grid cell (51-100) but only half the first.
      # A label of "1-50" would advertise 24 episodes the season does not have.
      chunks = Helpers.episode_chunks(episodes(25..100))

      assert Enum.map(chunks, &elem(&1, 0)) == ["51-100", "25-50"]
    end

    test "tolerates an unnumbered episode rather than raising" do
      episodes = [%Episode{season_number: 1, episode_number: nil} | episodes(1..60)]

      chunks = Helpers.episode_chunks(episodes)

      assert Enum.map(chunks, &elem(&1, 0)) == ["51-60", "1-50"]

      numbers =
        chunks
        |> Enum.flat_map(fn {_label, eps} -> eps end)
        |> Enum.map(& &1.episode_number)

      # Kept, not dropped: the row still renders, it just has no place on the grid.
      assert nil in numbers
      assert length(numbers) == 61
    end

    test "labels a chunk of nothing but unnumbered episodes from the grid" do
      episodes =
        for _ <- 1..51, do: %Episode{season_number: 1, episode_number: nil}

      assert [{"1-50", eps}] = Helpers.episode_chunks(episodes)
      assert length(eps) == 51
    end
  end

  describe "rendered chunking" do
    setup %{conn: conn} do
      admin = Mydia.AccountsFixtures.admin_user_fixture()
      %{conn: MydiaWeb.AuthHelpers.log_in_user(conn, admin)}
    end

    test "a 170-episode season renders chunk toggles instead of 170 rows", %{conn: conn} do
      show = chunky_show(episode_count: 170)

      {:ok, view, _html} = live(conn, ~p"/media/#{show.id}")

      assert has_element?(view, "#season-1-chunk-151-170-toggle")
      assert has_element?(view, "#season-1-chunk-1-50-toggle")
    end

    test "a small season renders no chunk toggles", %{conn: conn} do
      show = Mydia.MediaFixtures.media_item_fixture(%{type: "tv_show", title: "Small"})

      for n <- 1..10 do
        Mydia.MediaFixtures.episode_fixture(%{
          media_item_id: show.id,
          season_number: 1,
          episode_number: n
        })
      end

      {:ok, view, _html} = live(conn, ~p"/media/#{show.id}")

      refute has_element?(view, "[id^='season-1-chunk-']")
    end

    test "the newest chunk starts expanded, and can be collapsed and re-expanded by clicking",
         %{conn: conn} do
      show = chunky_show(episode_count: 170)

      {:ok, view, _html} = live(conn, ~p"/media/#{show.id}")

      # 151-170 is the newest range (episode_chunks/1 sorts newest first), so
      # it opens without a click.
      assert has_element?(view, "#season-1-chunk-151-170")

      view |> element("#season-1-chunk-151-170-toggle") |> render_click()
      refute has_element?(view, "#season-1-chunk-151-170")

      view |> element("#season-1-chunk-151-170-toggle") |> render_click()
      assert has_element?(view, "#season-1-chunk-151-170")
    end

    test "a non-newest chunk starts collapsed, and expands and collapses by clicking",
         %{conn: conn} do
      show = chunky_show(episode_count: 170)

      {:ok, view, _html} = live(conn, ~p"/media/#{show.id}")

      refute has_element?(view, "#season-1-chunk-1-50")

      view |> element("#season-1-chunk-1-50-toggle") |> render_click()
      assert has_element?(view, "#season-1-chunk-1-50")

      view |> element("#season-1-chunk-1-50-toggle") |> render_click()
      refute has_element?(view, "#season-1-chunk-1-50")
    end

    test "chunk expansion is keyed per season, so the same range label toggles independently",
         %{conn: conn} do
      show = Mydia.MediaFixtures.media_item_fixture(%{type: "tv_show", title: "TwoChunkySeasons"})

      for season <- [1, 2], n <- 1..60 do
        Mydia.MediaFixtures.episode_fixture(%{
          media_item_id: show.id,
          season_number: season,
          episode_number: n
        })
      end

      {:ok, view, _html} = live(conn, ~p"/media/#{show.id}")

      # Season 2 is the newest season, so it's the one expanded at mount by
      # default_expanded_seasons/2; expand season 1 too so both seasons'
      # "1-50" chunk toggles (the non-newest chunk in each, collapsed by
      # default) are on the page at once.
      view |> element("#season-1-toggle") |> render_click()

      refute has_element?(view, "#season-1-chunk-1-50")
      refute has_element?(view, "#season-2-chunk-1-50")

      view |> element("#season-1-chunk-1-50-toggle") |> render_click()

      assert has_element?(view, "#season-1-chunk-1-50")
      refute has_element?(view, "#season-2-chunk-1-50")
    end

    defp chunky_show(episode_count: episode_count) do
      show = Mydia.MediaFixtures.media_item_fixture(%{type: "tv_show", title: "Chunky"})

      for n <- 1..episode_count do
        Mydia.MediaFixtures.episode_fixture(%{
          media_item_id: show.id,
          season_number: 1,
          episode_number: n
        })
      end

      show
    end
  end
end
