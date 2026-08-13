defmodule Mydia.Streaming.ListActiveSessionsTest do
  # Drives the real session registry and a real DirectPlaySession, so the
  # sandbox has to be shared with those processes.
  use Mydia.DataCase, async: false

  alias Mydia.MediaFixtures
  alias Mydia.Streaming
  alias Mydia.Streaming.HlsSessionSupervisor

  defp start_direct_play(media_file, user) do
    {:ok, _pid, :started} = HlsSessionSupervisor.start_direct_session(media_file.id, user.id)

    on_exit(fn -> HlsSessionSupervisor.stop_direct_session(media_file.id, user.id) end)

    Enum.find(Streaming.list_active_sessions(), &(&1.media_file_id == media_file.id))
  end

  describe "list_active_sessions/0" do
    # A TV file carries episode_id with media_item_id NULL: the show hangs off
    # episode.media_item. Requiring media_file.media_item therefore dropped
    # every episode session, which on a TV-heavy library is nearly all of them,
    # and left the dashboard reporting zero viewers while a stream was running.
    test "an episode session reports the show and the episode" do
      show = MediaFixtures.media_item_fixture(%{type: "tv_show", title: "House of the Dragon"})

      episode =
        MediaFixtures.episode_fixture(%{
          media_item_id: show.id,
          season_number: 3,
          episode_number: 3,
          title: "The Burning Mill"
        })

      media_file = MediaFixtures.media_file_fixture(%{episode_id: episode.id, bitrate: 7_857_251})
      user = Mydia.AccountsFixtures.user_fixture()

      session = start_direct_play(media_file, user)

      assert session, "an active episode session must appear in the now-playing list"
      assert session.media_title == "House of the Dragon"
      assert session.media_type == :tv_show
      assert session.episode_info == "S03E03 - The Burning Mill"
      assert session.bitrate_bps == 7_857_251
      assert session.user.id == user.id
    end

    test "a movie session still reports the movie" do
      movie = MediaFixtures.media_item_fixture(%{type: "movie", title: "Arrival"})
      media_file = MediaFixtures.media_file_fixture(%{media_item_id: movie.id})
      user = Mydia.AccountsFixtures.user_fixture()

      session = start_direct_play(media_file, user)

      assert session
      assert session.media_title == "Arrival"
      assert session.media_type == :movie
      assert session.episode_info == nil
    end

    # The session's scrubber comes from the viewer's progress row, which for a
    # TV file is keyed by episode rather than by show.
    test "an episode session carries the viewer's saved position" do
      show = MediaFixtures.media_item_fixture(%{type: "tv_show"})
      episode = MediaFixtures.episode_fixture(%{media_item_id: show.id})
      media_file = MediaFixtures.media_file_fixture(%{episode_id: episode.id})
      user = Mydia.AccountsFixtures.user_fixture()

      {:ok, _} =
        Mydia.Playback.save_progress(user.id, [episode_id: episode.id], %{
          position_seconds: 62,
          duration_seconds: 3389
        })

      session = start_direct_play(media_file, user)

      assert session.position_seconds == 62
      assert session.duration_seconds == 3389
    end
  end
end
