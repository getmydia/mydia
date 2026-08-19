defmodule Mydia.Playback.DismissalTest do
  use Mydia.DataCase, async: true

  alias Mydia.AccountsFixtures
  alias Mydia.MediaFixtures
  alias Mydia.Playback
  alias Mydia.Playback.Dismissal

  setup do
    %{user: AccountsFixtures.user_fixture(), movie: MediaFixtures.media_item_fixture()}
  end

  describe "dismiss_from_on_deck/3" do
    test "records the dismissal against the user and item", ctx do
      assert {:ok, dismissal} = Playback.dismiss_from_on_deck(ctx.user.id, ctx.movie.id)

      assert dismissal.user_id == ctx.user.id
      assert dismissal.media_item_id == ctx.movie.id
      assert dismissal.dismissed_at
    end

    # A dismissed title comes back the moment it is played again, so dismissing
    # the same thing twice is ordinary use, not an error. An insert would fail
    # the second time on the unique index.
    test "re-dismissing re-stamps rather than failing on the unique index", ctx do
      earlier = ~U[2026-08-12 20:00:00Z]
      later = ~U[2026-08-12 21:00:00Z]

      {:ok, _first} = Playback.dismiss_from_on_deck(ctx.user.id, ctx.movie.id, now: earlier)
      {:ok, _second} = Playback.dismiss_from_on_deck(ctx.user.id, ctx.movie.id, now: later)

      # Read back rather than trusting the returned struct: an upsert hands
      # back the id it generated for the insert it did not end up doing.
      assert Repo.aggregate(Dismissal, :count) == 1
      assert stored = Repo.get_by(Dismissal, user_id: ctx.user.id, media_item_id: ctx.movie.id)
      assert DateTime.compare(stored.dismissed_at, later) == :eq
    end

    test "an id naming no media item is refused, not raised", ctx do
      assert {:error, :not_found} =
               Playback.dismiss_from_on_deck(ctx.user.id, Ecto.UUID.generate())

      assert Repo.aggregate(Dismissal, :count) == 0
    end

    test "an id that is not even a UUID is refused, not raised", ctx do
      assert {:error, :not_found} = Playback.dismiss_from_on_deck(ctx.user.id, "not-a-uuid")

      assert Repo.aggregate(Dismissal, :count) == 0
    end

    test "two users dismiss the same title independently", ctx do
      other = AccountsFixtures.user_fixture()

      {:ok, _} = Playback.dismiss_from_on_deck(ctx.user.id, ctx.movie.id)
      {:ok, _} = Playback.dismiss_from_on_deck(other.id, ctx.movie.id)

      assert Repo.aggregate(Dismissal, :count) == 2
    end

    test "truncates the stamp to the second, matching last_watched_at", ctx do
      {:ok, dismissal} = Playback.dismiss_from_on_deck(ctx.user.id, ctx.movie.id)

      assert dismissal.dismissed_at.microsecond == {0, 0}
    end

    # The reason this is a table of its own rather than a call to
    # `delete_progress/3`: that emits `playback.unwatched`, which WatchSync
    # forwards to Plex and Jellyfin. Hiding a card must stay local.
    #
    # The unwatch at the end is a positive control. Event writes run
    # synchronously under the sandbox pool, so without it a broken
    # subscription would make the `refute_receive` pass for the wrong reason.
    test "emits no event, where an unwatch would", ctx do
      {:ok, _} =
        Playback.save_progress(
          ctx.user.id,
          [media_item_id: ctx.movie.id],
          %{position_seconds: 900, duration_seconds: 7200}
        )

      Mydia.Events.subscribe()

      {:ok, _} = Playback.dismiss_from_on_deck(ctx.user.id, ctx.movie.id)

      refute_receive {:event_created, %{type: "playback.unwatched"}}, 100

      {:ok, _} = Playback.delete_progress(ctx.user.id, media_item_id: ctx.movie.id)

      assert_receive {:event_created, %{type: "playback.unwatched"}}, 100
    end
  end
end
