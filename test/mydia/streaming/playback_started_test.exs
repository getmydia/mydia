defmodule Mydia.Streaming.PlaybackStartedTest do
  use Mydia.DataCase, async: true

  import Ecto.Query

  alias Mydia.Events.Event
  alias Mydia.Repo
  alias Mydia.Streaming

  defp started_events do
    Repo.all(from e in Event, where: e.type == "playback.started")
  end

  test "emits an episode play for a file attached to an episode" do
    show = Mydia.MediaFixtures.media_item_fixture(%{type: "tv_show"})
    episode = Mydia.MediaFixtures.episode_fixture(%{media_item_id: show.id})
    media_file = Mydia.MediaFixtures.media_file_fixture(%{episode_id: episode.id})
    user = Mydia.AccountsFixtures.user_fixture()

    :ok = Streaming.emit_playback_started(media_file.id, user.id)

    # Events are written asynchronously; give the cast a moment to land.
    Process.sleep(50)

    assert [event] = started_events()
    assert event.resource_type == "episode"
    assert event.resource_id == episode.id
    assert event.actor_id == user.id
  end

  test "emits a movie play for a file attached to a media item" do
    movie = Mydia.MediaFixtures.media_item_fixture(%{type: "movie"})
    media_file = Mydia.MediaFixtures.media_file_fixture(%{media_item_id: movie.id})
    user = Mydia.AccountsFixtures.user_fixture()

    :ok = Streaming.emit_playback_started(media_file.id, user.id)

    Process.sleep(50)

    assert [event] = started_events()
    assert event.resource_type == "media_item"
    assert event.resource_id == movie.id
  end

  test "emits nothing for a media file that no longer exists" do
    user = Mydia.AccountsFixtures.user_fixture()

    :ok = Streaming.emit_playback_started(Ecto.UUID.generate(), user.id)

    Process.sleep(50)

    assert started_events() == []
  end
end
