defmodule Mydia.PlaybackRecentHistoryTest do
  use Mydia.DataCase, async: true

  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Playback

  describe "list_recent_history/1 with episodes" do
    test "an episode row carries its show through the preload" do
      user = user_fixture()
      show = media_item_fixture(%{type: "tv_show", title: "The Expanse"})
      episode = episode_fixture(%{media_item_id: show.id, season_number: 2, episode_number: 5})

      {:ok, _} =
        Playback.save_progress(user.id, [episode_id: episode.id], %{
          position_seconds: 300,
          duration_seconds: 2700
        })

      assert [progress] = Playback.list_recent_history(limit: 10)

      # The bug: media_item is nil on an episode row, so the show title has to
      # come through the episode association.
      assert is_nil(progress.media_item)
      assert progress.episode.media_item.title == "The Expanse"
    end
  end

  describe "progress_title/1" do
    test "renders show, season and episode for an episode row" do
      user = user_fixture()
      show = media_item_fixture(%{type: "tv_show", title: "The Expanse"})
      episode = episode_fixture(%{media_item_id: show.id, season_number: 2, episode_number: 5})

      {:ok, _} =
        Playback.save_progress(user.id, [episode_id: episode.id], %{
          position_seconds: 300,
          duration_seconds: 2700
        })

      [progress] = Playback.list_recent_history(limit: 10)

      assert Playback.progress_title(progress) == "The Expanse - S02E05"
    end

    test "renders the title for a movie row" do
      user = user_fixture()
      movie = media_item_fixture(%{type: "movie", title: "Arrival"})

      {:ok, _} =
        Playback.save_progress(user.id, [media_item_id: movie.id], %{
          position_seconds: 300,
          duration_seconds: 6900
        })

      [progress] = Playback.list_recent_history(limit: 10)

      assert Playback.progress_title(progress) == "Arrival"
    end

    test "falls back only when neither association is loaded" do
      assert Playback.progress_title(%Mydia.Playback.Progress{}) == "Unknown Media"
    end
  end
end
