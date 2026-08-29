defmodule Mydia.Library.EpisodeMinterTest do
  use Mydia.DataCase, async: true

  import Mydia.MediaFixtures

  alias Mydia.Library.EpisodeMinter
  alias Mydia.Media

  defp show_with_episodes(coords) do
    show = media_item_fixture(%{type: "tv_show", title: "Minter Show"})

    for {season, episode} <- coords do
      {:ok, _} =
        Media.create_episode(%{
          media_item_id: show.id,
          season_number: season,
          episode_number: episode
        })
    end

    Media.get_media_item!(show.id)
  end

  describe "mintable?/3" do
    setup do
      %{show: show_with_episodes([{1, 21}, {2, 21}, {3, 16}])}
    end

    test "accepts the season after the last known one", %{show: show} do
      assert EpisodeMinter.mintable?(show, 4, 1)
    end

    test "accepts an episode at the ceiling", %{show: show} do
      assert EpisodeMinter.mintable?(show, 4, 31)
    end

    test "refuses a season two beyond the last known one", %{show: show} do
      refute EpisodeMinter.mintable?(show, 5, 1)
    end

    test "refuses season zero", %{show: show} do
      refute EpisodeMinter.mintable?(show, 0, 1)
    end

    test "refuses a negative season", %{show: show} do
      refute EpisodeMinter.mintable?(show, -1, 1)
    end

    test "refuses an episode past the ceiling", %{show: show} do
      refute EpisodeMinter.mintable?(show, 4, 32)
    end

    test "refuses episode zero", %{show: show} do
      refute EpisodeMinter.mintable?(show, 4, 0)
    end

    test "refuses non-integer coordinates", %{show: show} do
      refute EpisodeMinter.mintable?(show, nil, 1)
      refute EpisodeMinter.mintable?(show, 4, nil)
    end

    test "a show with no episodes still accepts a full first season" do
      show = show_with_episodes([])

      assert EpisodeMinter.mintable?(show, 1, 22)
      refute EpisodeMinter.mintable?(show, 1, 31)
      refute EpisodeMinter.mintable?(show, 2, 1)
    end

    test "a high-numbered special does not inflate the ceiling for a regular season" do
      show = show_with_episodes([{1, 21}, {2, 21}, {3, 16}, {0, 187}])

      # Without excluding season 0 from Media.episode_bounds/1, max_episode
      # would be 187 and the ceiling max(187 + 10, 30) = 197 would accept
      # this misparsed coordinate.
      refute EpisodeMinter.mintable?(show, 4, 190)
    end
  end

  describe "mint/4" do
    setup do
      %{show: show_with_episodes([{1, 21}, {2, 21}, {3, 16}])}
    end

    test "creates an untagged episode carrying the filename title", %{show: show} do
      assert {:ok, episode} =
               EpisodeMinter.mint(show, 4, 1, "Show (2022) - S04E01 - La soirée pyjama.mkv")

      assert episode.season_number == 4
      assert episode.episode_number == 1
      assert episode.title == "La soirée pyjama"
      assert is_nil(episode.provider_episode_id)
    end

    test "creates a titleless episode for a scene release", %{show: show} do
      assert {:ok, episode} =
               EpisodeMinter.mint(show, 4, 2, "Show.S04E02.1080p.WEB-DL.x264-GRP.mkv")

      assert is_nil(episode.title)
    end

    test "refuses an implausible coordinate without writing", %{show: show} do
      assert {:error, :implausible} = EpisodeMinter.mint(show, 99, 1, "Show - S99E01.mkv")
      assert is_nil(Media.get_episode_by_number(show.id, 99, 1))
    end

    test "returns the existing row when one is already there", %{show: show} do
      {:ok, first} = EpisodeMinter.mint(show, 4, 3, "Show - S04E03 - La chorale.mkv")
      assert {:ok, second} = EpisodeMinter.mint(show, 4, 3, "Show - S04E03 - La chorale.mkv")

      assert first.id == second.id
    end
  end
end
