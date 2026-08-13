defmodule Mydia.Playback.RecentPlaysTest do
  use Mydia.DataCase, async: true

  alias Mydia.AccountsFixtures
  alias Mydia.MediaFixtures
  alias Mydia.Playback
  alias Mydia.Playback.Stats
  alias Mydia.Streaming

  defp episode_file(attrs \\ %{}) do
    show = MediaFixtures.media_item_fixture(Map.merge(%{type: "tv_show"}, attrs))
    episode = MediaFixtures.episode_fixture(%{media_item_id: show.id})
    media_file = MediaFixtures.media_file_fixture(%{episode_id: episode.id})

    {show, episode, media_file}
  end

  # Ordering needs timestamps the emitter cannot produce on demand, so those
  # cases write the event row the emitter would have written.
  defp insert_start(user_id, episode_id, at) do
    Repo.insert!(%Mydia.Events.Event{
      category: "playback",
      type: "playback.started",
      actor_type: :user,
      actor_id: user_id,
      resource_type: "episode",
      resource_id: episode_id,
      metadata: %{"episode_id" => episode_id, "origin" => "player"},
      inserted_at: at
    })
  end

  describe "recent_plays/1" do
    test "a play started on this server is listed" do
      {show, _episode, media_file} = episode_file(%{title: "House of the Dragon"})
      user = AccountsFixtures.user_fixture()

      :ok = Streaming.emit_playback_started(media_file.id, user.id)

      assert [play] = Stats.recent_plays(10)
      assert Playback.progress_title(play) =~ show.title
      assert play.user.id == user.id
      assert play.last_watched_at
    end

    test "a movie play is listed" do
      movie = MediaFixtures.media_item_fixture(%{type: "movie", title: "Arrival"})
      media_file = MediaFixtures.media_file_fixture(%{media_item_id: movie.id})
      user = AccountsFixtures.user_fixture()

      :ok = Streaming.emit_playback_started(media_file.id, user.id)

      assert [play] = Stats.recent_plays(10)
      assert Playback.progress_title(play) == "Arrival"
    end

    # The bug this function exists to fix. A media-server sync writes progress
    # for watches that happened on somebody else's box, and stamps
    # `last_watched_at` with the sync time whenever the remote carries no
    # timestamp, so an import buried every real play under a wall of history
    # that was never watched here.
    test "a media-server sync is not a play" do
      {_show, episode, _media_file} = episode_file()
      user = AccountsFixtures.user_fixture()

      Playback.ensure_watched(user.id, [episode_id: episode.id], origin: "sync:plex")

      assert Stats.recent_plays(10) == []
    end

    test "sync writes never outrank a real play" do
      {_show, watched_episode, _} = episode_file()
      {show, _episode, media_file} = episode_file(%{title: "The Expanse"})
      user = AccountsFixtures.user_fixture()

      :ok = Streaming.emit_playback_started(media_file.id, user.id)
      Playback.ensure_watched(user.id, [episode_id: watched_episode.id], origin: "sync:plex")

      assert [play] = Stats.recent_plays(10)
      assert Playback.progress_title(play) =~ show.title
    end

    # `events.inserted_at` is second-granularity, so ordering is asserted on
    # plays a minute apart. Two plays inside the same second fall back to a
    # tiebreak that is stable between renders but not chronological, which for
    # an activity feed is immaterial.
    test "newest first" do
      {_show, older_episode, _} = episode_file(%{title: "Older"})
      {_show, newer_episode, _} = episode_file(%{title: "Newer"})
      user = AccountsFixtures.user_fixture()

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      insert_start(user.id, older_episode.id, DateTime.add(now, -60, :second))
      insert_start(user.id, newer_episode.id, now)

      titles = Stats.recent_plays(10) |> Enum.map(&Playback.progress_title/1)

      assert length(titles) == 2
      assert hd(titles) =~ "Newer"
    end

    # A session that restarts mid-stream, which the offset-mismatch path does,
    # emits a second start for the same content. One viewer watching one thing
    # is one row in the activity feed.
    test "a repeated start on the same content is listed once" do
      {_show, _episode, media_file} = episode_file()
      user = AccountsFixtures.user_fixture()

      :ok = Streaming.emit_playback_started(media_file.id, user.id)
      :ok = Streaming.emit_playback_started(media_file.id, user.id)

      assert [_single] = Stats.recent_plays(10)
    end

    test "honours the limit" do
      user = AccountsFixtures.user_fixture()

      for _ <- 1..3 do
        {_show, _episode, media_file} = episode_file()
        :ok = Streaming.emit_playback_started(media_file.id, user.id)
      end

      assert length(Stats.recent_plays(2)) == 2
    end

    # Deleting a show must not take the dashboard down with it.
    test "a play whose content has been deleted is skipped" do
      {_show, episode, media_file} = episode_file()
      user = AccountsFixtures.user_fixture()

      :ok = Streaming.emit_playback_started(media_file.id, user.id)
      Repo.delete!(episode)

      assert Stats.recent_plays(10) == []
    end
  end
end
