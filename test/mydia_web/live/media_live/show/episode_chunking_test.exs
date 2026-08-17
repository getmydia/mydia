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
  end

  describe "rendered chunking" do
    setup %{conn: conn} do
      admin = Mydia.AccountsFixtures.admin_user_fixture()
      %{conn: MydiaWeb.AuthHelpers.log_in_user(conn, admin)}
    end

    test "a 170-episode season renders chunk toggles instead of 170 rows", %{conn: conn} do
      show = Mydia.MediaFixtures.media_item_fixture(%{type: "tv_show", title: "Chunky"})

      for n <- 1..170 do
        Mydia.MediaFixtures.episode_fixture(%{
          media_item_id: show.id,
          season_number: 1,
          episode_number: n
        })
      end

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
  end
end
