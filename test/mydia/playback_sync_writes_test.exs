defmodule Mydia.PlaybackSyncWritesTest do
  use Mydia.DataCase, async: true

  import Mydia.MediaFixtures
  import Mydia.AccountsFixtures

  alias Mydia.Playback
  alias Mydia.Playback.Progress

  setup do
    {:ok, user: user_fixture(), movie: media_item_fixture()}
  end

  test "an authoritative unwatched flag survives the 90% auto-mark", %{user: user, movie: movie} do
    # Plex reports a viewOffset near the end but viewCount 0, meaning the user
    # scrubbed and never finished. Auto-marking it watched would diverge from
    # the server on the very first sync.
    changeset =
      Progress.changeset(
        %Progress{},
        %{
          user_id: user.id,
          media_item_id: movie.id,
          position_seconds: 920,
          duration_seconds: 1000,
          watched: false
        },
        authoritative_watched: true
      )

    assert Ecto.Changeset.get_field(changeset, :watched) == false
  end

  test "without the option the 90% auto-mark still applies", %{user: user, movie: movie} do
    changeset =
      Progress.changeset(%Progress{}, %{
        user_id: user.id,
        media_item_id: movie.id,
        position_seconds: 920,
        duration_seconds: 1000,
        watched: false
      })

    assert Ecto.Changeset.get_field(changeset, :watched) == true
  end

  test "an explicit last_watched_at is preserved, not overwritten with now",
       %{user: user, movie: movie} do
    # The reconciler resolves conflicts by comparing exactly this timestamp, so
    # stamping `now` on every sync write would corrupt its own inputs.
    watched_at = ~U[2026-01-01 00:00:00Z]

    {:ok, progress} =
      Playback.save_progress(
        user.id,
        [media_item_id: movie.id],
        %{position_seconds: 10, duration_seconds: 100, last_watched_at: watched_at}
      )

    assert DateTime.compare(progress.last_watched_at, watched_at) == :eq
  end

  test "deleting progress emits a playback.unwatched event", %{user: user, movie: movie} do
    {:ok, _} =
      Playback.save_progress(user.id, [media_item_id: movie.id], %{
        position_seconds: 10,
        duration_seconds: 100
      })

    Phoenix.PubSub.subscribe(Mydia.PubSub, "events:all")

    {:ok, _} = Playback.delete_progress(user.id, media_item_id: movie.id)

    assert_receive {:event_created, %{type: "playback.unwatched"}}, 2_000
  end
end
