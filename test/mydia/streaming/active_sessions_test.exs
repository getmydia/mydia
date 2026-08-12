defmodule Mydia.Streaming.ActiveSessionsTest do
  use Mydia.DataCase, async: true

  alias Mydia.Playback
  alias Mydia.Streaming
  alias Mydia.Streaming.ActiveSession

  test "the struct carries the fields the now-playing card needs" do
    session = %ActiveSession{}

    assert Map.has_key?(session, :media_file_id)
    assert Map.has_key?(session, :bitrate_bps)
    assert Map.has_key?(session, :position_seconds)
    assert Map.has_key?(session, :duration_seconds)
  end

  # list_active_sessions/0 needs a live session registry to reach, so its
  # progress join is covered here through the extracted key derivation instead.
  # Getting this wrong does not crash: the card just renders with no scrubber,
  # which is exactly the kind of silent loss no other test would notice.
  describe "progress_content_id/1" do
    test "an episode file resolves to its episode, not its show" do
      show = Mydia.MediaFixtures.media_item_fixture(%{type: "tv_show"})
      episode = Mydia.MediaFixtures.episode_fixture(%{media_item_id: show.id})
      media_file = Mydia.MediaFixtures.media_file_fixture(%{episode_id: episode.id})

      assert Streaming.progress_content_id(media_file) == [episode_id: episode.id]
    end

    test "a movie file resolves to its media item" do
      movie = Mydia.MediaFixtures.media_item_fixture(%{type: "movie"})
      media_file = Mydia.MediaFixtures.media_file_fixture(%{media_item_id: movie.id})

      assert Streaming.progress_content_id(media_file) == [media_item_id: movie.id]
    end

    test "the derived key finds an episode's saved progress" do
      show = Mydia.MediaFixtures.media_item_fixture(%{type: "tv_show"})
      episode = Mydia.MediaFixtures.episode_fixture(%{media_item_id: show.id})
      media_file = Mydia.MediaFixtures.media_file_fixture(%{episode_id: episode.id})
      user = Mydia.AccountsFixtures.user_fixture()

      {:ok, _} =
        Playback.save_progress(user.id, [episode_id: episode.id], %{
          position_seconds: 420,
          duration_seconds: 2700
        })

      progress = Playback.get_progress(user.id, Streaming.progress_content_id(media_file))

      assert progress
      assert progress.position_seconds == 420
    end

    test "the derived key finds a movie's saved progress" do
      movie = Mydia.MediaFixtures.media_item_fixture(%{type: "movie"})
      media_file = Mydia.MediaFixtures.media_file_fixture(%{media_item_id: movie.id})
      user = Mydia.AccountsFixtures.user_fixture()

      {:ok, _} =
        Playback.save_progress(user.id, [media_item_id: movie.id], %{
          position_seconds: 900,
          duration_seconds: 6900
        })

      progress = Playback.get_progress(user.id, Streaming.progress_content_id(media_file))

      assert progress
      assert progress.position_seconds == 900
    end
  end
end
