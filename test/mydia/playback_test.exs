defmodule Mydia.PlaybackTest do
  use Mydia.DataCase, async: true

  alias Mydia.Playback
  alias Mydia.Accounts
  alias Mydia.Accounts.Scope
  alias Mydia.Events
  alias Mydia.Media

  describe "get_progress/2" do
    setup do
      {:ok, user} = create_user()
      {:ok, media_item} = create_media_item()
      {:ok, episode} = create_episode()

      %{user: user, media_item: media_item, episode: episode}
    end

    test "returns progress for a media item", %{user: user, media_item: media_item} do
      {:ok, _progress} =
        Playback.save_progress(user.id, [media_item_id: media_item.id], %{
          position_seconds: 120,
          duration_seconds: 3600
        })

      progress = Playback.get_progress(user.id, media_item_id: media_item.id)

      assert progress.position_seconds == 120
      assert progress.duration_seconds == 3600
      assert progress.user_id == user.id
      assert progress.media_item_id == media_item.id
    end

    test "returns progress for an episode", %{user: user, episode: episode} do
      {:ok, _progress} =
        Playback.save_progress(user.id, [episode_id: episode.id], %{
          position_seconds: 300,
          duration_seconds: 1800
        })

      progress = Playback.get_progress(user.id, episode_id: episode.id)

      assert progress.position_seconds == 300
      assert progress.duration_seconds == 1800
      assert progress.user_id == user.id
      assert progress.episode_id == episode.id
    end

    test "returns nil when no progress exists", %{user: user, media_item: media_item} do
      assert Playback.get_progress(user.id, media_item_id: media_item.id) == nil
    end
  end

  describe "save_progress/3" do
    setup do
      {:ok, user} = create_user()
      {:ok, media_item} = create_media_item()
      {:ok, episode} = create_episode()

      %{user: user, media_item: media_item, episode: episode}
    end

    test "creates new progress for a media item", %{user: user, media_item: media_item} do
      {:ok, progress} =
        Playback.save_progress(user.id, [media_item_id: media_item.id], %{
          position_seconds: 120,
          duration_seconds: 3600
        })

      assert progress.position_seconds == 120
      assert progress.duration_seconds == 3600
      assert_in_delta progress.completion_percentage, 3.333, 0.01
      assert progress.watched == false
      assert progress.last_watched_at != nil
    end

    test "creates new progress for an episode", %{user: user, episode: episode} do
      {:ok, progress} =
        Playback.save_progress(user.id, [episode_id: episode.id], %{
          position_seconds: 300,
          duration_seconds: 1800
        })

      assert progress.position_seconds == 300
      assert progress.duration_seconds == 1800
      assert progress.episode_id == episode.id
    end

    test "updates existing progress", %{user: user, media_item: media_item} do
      {:ok, _progress} =
        Playback.save_progress(user.id, [media_item_id: media_item.id], %{
          position_seconds: 120,
          duration_seconds: 3600
        })

      {:ok, updated_progress} =
        Playback.save_progress(user.id, [media_item_id: media_item.id], %{
          position_seconds: 240,
          duration_seconds: 3600
        })

      assert updated_progress.position_seconds == 240
      assert updated_progress.duration_seconds == 3600

      # Verify only one record exists
      assert [_single_progress] = Playback.list_user_progress(user.id)
    end

    test "automatically calculates completion percentage", %{user: user, media_item: media_item} do
      {:ok, progress} =
        Playback.save_progress(user.id, [media_item_id: media_item.id], %{
          position_seconds: 1800,
          duration_seconds: 3600
        })

      assert progress.completion_percentage == 50.0

      # Test with non-round percentage
      {:ok, progress2} =
        Playback.save_progress(user.id, [media_item_id: media_item.id], %{
          position_seconds: 120,
          duration_seconds: 3600
        })

      assert_in_delta progress2.completion_percentage, 3.333, 0.01
    end

    test "automatically marks as watched when >= 90%", %{user: user, media_item: media_item} do
      {:ok, progress} =
        Playback.save_progress(user.id, [media_item_id: media_item.id], %{
          position_seconds: 3300,
          duration_seconds: 3600
        })

      assert progress.completion_percentage >= 90.0
      assert progress.watched == true
    end

    test "does not mark as watched when < 90%", %{user: user, media_item: media_item} do
      {:ok, progress} =
        Playback.save_progress(user.id, [media_item_id: media_item.id], %{
          position_seconds: 3000,
          duration_seconds: 3600
        })

      assert progress.completion_percentage < 90.0
      assert progress.watched == false
    end

    test "requires positive position", %{user: user, media_item: media_item} do
      {:error, changeset} =
        Playback.save_progress(user.id, [media_item_id: media_item.id], %{
          position_seconds: -1,
          duration_seconds: 3600
        })

      assert "must be greater than or equal to 0" in errors_on(changeset).position_seconds
    end

    test "requires positive duration", %{user: user, media_item: media_item} do
      {:error, changeset} =
        Playback.save_progress(user.id, [media_item_id: media_item.id], %{
          position_seconds: 120,
          duration_seconds: 0
        })

      assert "must be greater than 0" in errors_on(changeset).duration_seconds
    end

    test "enforces unique constraint per user/media_item", %{user: user, media_item: media_item} do
      {:ok, user2} = create_user()

      # Same media item, different users - should succeed
      {:ok, _progress1} =
        Playback.save_progress(user.id, [media_item_id: media_item.id], %{
          position_seconds: 120,
          duration_seconds: 3600
        })

      {:ok, _progress2} =
        Playback.save_progress(user2.id, [media_item_id: media_item.id], %{
          position_seconds: 240,
          duration_seconds: 3600
        })

      # Verify two separate records exist
      assert [_p1] = Playback.list_user_progress(user.id)
      assert [_p2] = Playback.list_user_progress(user2.id)
    end
  end

  describe "list_user_progress/2" do
    setup do
      {:ok, user} = create_user()
      {:ok, media_item1} = create_media_item()
      {:ok, media_item2} = create_media_item()
      {:ok, episode} = create_episode()

      # Create some progress records
      {:ok, _} =
        Playback.save_progress(user.id, [media_item_id: media_item1.id], %{
          position_seconds: 120,
          duration_seconds: 3600
        })

      {:ok, _} =
        Playback.save_progress(user.id, [media_item_id: media_item2.id], %{
          position_seconds: 3300,
          duration_seconds: 3600
        })

      {:ok, _} =
        Playback.save_progress(user.id, [episode_id: episode.id], %{
          position_seconds: 500,
          duration_seconds: 1800
        })

      %{user: user}
    end

    test "returns all progress for a user", %{user: user} do
      progress_list = Playback.list_user_progress(user.id)

      assert length(progress_list) == 3
    end

    test "filters by watched status", %{user: user} do
      # One item should be marked as watched (>= 90%)
      watched = Playback.list_user_progress(user.id, watched: true)
      unwatched = Playback.list_user_progress(user.id, watched: false)

      assert length(watched) == 1
      assert length(unwatched) == 2
    end

    test "limits results", %{user: user} do
      progress_list = Playback.list_user_progress(user.id, limit: 2)

      assert length(progress_list) == 2
    end

    test "orders by last_watched_at by default", %{user: user} do
      progress_list = Playback.list_user_progress(user.id)

      # All should have last_watched_at set
      assert Enum.all?(progress_list, & &1.last_watched_at)
    end
  end

  describe "mark_watched/2" do
    setup do
      {:ok, user} = create_user()
      {:ok, media_item} = create_media_item()

      {:ok, _progress} =
        Playback.save_progress(user.id, [media_item_id: media_item.id], %{
          position_seconds: 120,
          duration_seconds: 3600
        })

      %{user: user, media_item: media_item}
    end

    test "marks progress as watched", %{user: user, media_item: media_item} do
      {:ok, progress} = Playback.mark_watched(user.id, media_item_id: media_item.id)

      assert progress.watched == true
    end

    test "returns error when progress doesn't exist", %{user: user} do
      {:ok, other_media_item} = create_media_item()

      assert {:error, :not_found} =
               Playback.mark_watched(user.id, media_item_id: other_media_item.id)
    end
  end

  describe "delete_progress/2" do
    setup do
      {:ok, user} = create_user()
      {:ok, media_item} = create_media_item()

      {:ok, _progress} =
        Playback.save_progress(user.id, [media_item_id: media_item.id], %{
          position_seconds: 120,
          duration_seconds: 3600
        })

      %{user: user, media_item: media_item}
    end

    test "deletes progress record", %{user: user, media_item: media_item} do
      {:ok, _deleted} = Playback.delete_progress(user.id, media_item_id: media_item.id)

      assert Playback.get_progress(user.id, media_item_id: media_item.id) == nil
    end

    test "returns error when progress doesn't exist", %{user: user} do
      {:ok, other_media_item} = create_media_item()

      assert {:error, :not_found} =
               Playback.delete_progress(user.id, media_item_id: other_media_item.id)
    end
  end

  describe "mark_season_watched/3 and mark_season_unwatched/3" do
    setup do
      {:ok, user} = create_user()
      {:ok, show} = create_show()
      [e1, e2, e3] = for n <- 1..3, do: create_episode_in(show, 1, n)
      %{user: user, show: show, e1: e1, e2: e2, e3: e3}
    end

    test "marks every episode in the season watched", ctx do
      assert :ok = Playback.mark_season_watched(ctx.user.id, ctx.show.id, 1)

      for ep <- [ctx.e1, ctx.e2, ctx.e3] do
        assert Playback.get_progress(ctx.user.id, episode_id: ep.id).watched == true
      end
    end

    test "is idempotent over already-watched episodes", ctx do
      :changed = Playback.ensure_watched(ctx.user.id, episode_id: ctx.e1.id)

      assert :ok = Playback.mark_season_watched(ctx.user.id, ctx.show.id, 1)

      for ep <- [ctx.e1, ctx.e2, ctx.e3] do
        assert Playback.get_progress(ctx.user.id, episode_id: ep.id).watched == true
      end
    end

    # Covers AE2: in-progress resume positions are discarded along with watched rows.
    test "mark_season_unwatched deletes every progress row, including in-progress resume positions",
         ctx do
      :changed = Playback.ensure_watched(ctx.user.id, episode_id: ctx.e1.id)

      {:ok, _} =
        Playback.save_progress(ctx.user.id, [episode_id: ctx.e2.id], %{
          position_seconds: 60,
          duration_seconds: 100
        })

      :changed = Playback.ensure_watched(ctx.user.id, episode_id: ctx.e3.id)

      assert :ok = Playback.mark_season_unwatched(ctx.user.id, ctx.show.id, 1)

      for ep <- [ctx.e1, ctx.e2, ctx.e3] do
        assert Playback.get_progress(ctx.user.id, episode_id: ep.id) == nil
      end
    end

    test "mark_season_unwatched on a season with no progress is a no-op", ctx do
      assert :ok = Playback.mark_season_unwatched(ctx.user.id, ctx.show.id, 1)
    end

    test "an empty or invalid season number is a no-op", ctx do
      assert :ok = Playback.mark_season_watched(ctx.user.id, ctx.show.id, 99)
      assert :ok = Playback.mark_season_unwatched(ctx.user.id, ctx.show.id, 99)
    end
  end

  describe "mark_episodes_up_to_watched/3" do
    setup do
      {:ok, user} = create_user()
      {:ok, show} = create_show()
      episodes = for n <- 1..6, do: create_episode_in(show, 1, n)
      %{user: user, show: show, episodes: episodes}
    end

    # Covers AE1.
    test "marks the anchor and all earlier episodes, leaving later ones untouched", ctx do
      [e1, e2, e3, e4, e5, e6] = ctx.episodes
      :changed = Playback.ensure_watched(ctx.user.id, episode_id: e1.id)
      :changed = Playback.ensure_watched(ctx.user.id, episode_id: e2.id)

      {:ok, _} =
        Playback.save_progress(ctx.user.id, [episode_id: e3.id], %{
          position_seconds: 40,
          duration_seconds: 100
        })

      assert :ok = Playback.mark_episodes_up_to_watched(ctx.user.id, e4.id)

      for ep <- [e1, e2, e3, e4] do
        assert Playback.get_progress(ctx.user.id, episode_id: ep.id).watched == true
      end

      assert Playback.get_progress(ctx.user.id, episode_id: e5.id) == nil
      assert Playback.get_progress(ctx.user.id, episode_id: e6.id) == nil
    end

    test "does not affect episodes in other seasons sharing the same episode_number", ctx do
      [_e1, _e2, _e3, e4, _e5, _e6] = ctx.episodes
      s2e4 = create_episode_in(ctx.show, 2, 4)

      assert :ok = Playback.mark_episodes_up_to_watched(ctx.user.id, e4.id)

      assert Playback.get_progress(ctx.user.id, episode_id: s2e4.id) == nil
    end

    test "a missing episode is a no-op", ctx do
      assert :ok = Playback.mark_episodes_up_to_watched(ctx.user.id, Ecto.UUID.generate())
    end
  end

  describe "explicit watched-action event semantics (U3)" do
    setup do
      {:ok, user} = create_user()
      {:ok, show} = create_show()
      episodes = for n <- 1..3, do: create_episode_in(show, 1, n)
      %{user: user, show: show, episodes: episodes}
    end

    test "re-marking an already-watched season emits no new finished events", ctx do
      :ok = Playback.mark_season_watched(ctx.user.id, ctx.show.id, 1)
      assert length(playback_events(ctx.user, "finished")) == 3

      :ok = Playback.mark_season_watched(ctx.user.id, ctx.show.id, 1)
      assert length(playback_events(ctx.user, "finished")) == 3
    end

    test "marking a partially-watched season emits finished only for previously-unwatched episodes",
         ctx do
      [e1, _e2, _e3] = ctx.episodes
      :changed = Playback.ensure_watched(ctx.user.id, episode_id: e1.id)
      assert length(playback_events(ctx.user, "finished")) == 1

      :ok = Playback.mark_season_watched(ctx.user.id, ctx.show.id, 1)
      # Only e2 and e3 cross the unwatched -> watched edge.
      assert length(playback_events(ctx.user, "finished")) == 3
    end

    test "mark_season_unwatched emits no playback event", ctx do
      :ok = Playback.mark_season_watched(ctx.user.id, ctx.show.id, 1)
      finished_before = playback_events(ctx.user, "finished")
      progressed_before = playback_events(ctx.user, "progressed")

      :ok = Playback.mark_season_unwatched(ctx.user.id, ctx.show.id, 1)

      assert playback_events(ctx.user, "finished") == finished_before
      assert playback_events(ctx.user, "progressed") == progressed_before
    end

    test "mark_episodes_up_to_watched sets watched regardless of completion_percentage", ctx do
      [e1, _e2, _e3] = ctx.episodes

      {:ok, progress} =
        Playback.save_progress(ctx.user.id, [episode_id: e1.id], %{
          position_seconds: 10,
          duration_seconds: 100
        })

      assert progress.completion_percentage < 90.0
      assert progress.watched == false

      :ok = Playback.mark_episodes_up_to_watched(ctx.user.id, e1.id)

      updated = Playback.get_progress(ctx.user.id, episode_id: e1.id)
      # The watched boolean EpisodeCard reads is set without crossing 90%.
      assert updated.watched == true
      assert updated.completion_percentage < 90.0
    end
  end

  # Helper functions for test setup
  describe "playback events (U1)" do
    setup do
      {:ok, user} = create_user()
      {:ok, media_item} = create_media_item()
      {:ok, episode} = create_episode()
      %{user: user, media_item: media_item, episode: episode}
    end

    defp playback_events(user, action) do
      Events.list_events(
        type: "playback.#{action}",
        actor_type: :user,
        actor_id: user.id
      )
    end

    test "save_progress crossing 90% emits one finished with origin player and actor_id",
         %{user: user, media_item: media_item} do
      {:ok, _} =
        Playback.save_progress(user.id, [media_item_id: media_item.id], %{
          position_seconds: 95,
          duration_seconds: 100
        })

      assert [event] = playback_events(user, "finished")
      assert event.actor_id == user.id
      assert event.actor_type == :user
      assert event.resource_type == "media_item"
      assert event.resource_id == media_item.id
      assert event.metadata["origin"] == "player"
      assert event.metadata["watched"] == true
      # A finished write does not also emit a progressed for the same call.
      assert playback_events(user, "progressed") == []
    end

    test "rapid save_progress within one bucket emits a single progressed",
         %{user: user, media_item: media_item} do
      # All four writes land in the same 5% bucket (10..14%); only the first,
      # which crosses into the bucket, emits.
      for pos <- [10, 11, 12, 13] do
        {:ok, _} =
          Playback.save_progress(user.id, [media_item_id: media_item.id], %{
            position_seconds: pos,
            duration_seconds: 100
          })
      end

      assert [_one] = playback_events(user, "progressed")
    end

    test "crossing into a new bucket emits an additional progressed",
         %{user: user, media_item: media_item} do
      {:ok, _} =
        Playback.save_progress(user.id, [media_item_id: media_item.id], %{
          position_seconds: 10,
          duration_seconds: 100
        })

      {:ok, _} =
        Playback.save_progress(user.id, [media_item_id: media_item.id], %{
          position_seconds: 40,
          duration_seconds: 100
        })

      assert length(playback_events(user, "progressed")) == 2
    end

    test "mark_watched on an already-watched row emits nothing",
         %{user: user, media_item: media_item} do
      {:ok, _} =
        Playback.save_progress(user.id, [media_item_id: media_item.id], %{
          position_seconds: 95,
          duration_seconds: 100
        })

      assert [_only] = playback_events(user, "finished")

      {:ok, _} = Playback.mark_watched(user.id, media_item_id: media_item.id)

      # Still exactly one — the idempotent re-mark emitted no new finished.
      assert [_only] = playback_events(user, "finished")
    end

    test "mark_watched on an unwatched row emits one finished",
         %{user: user, episode: episode} do
      {:ok, _} =
        Playback.save_progress(user.id, [episode_id: episode.id], %{
          position_seconds: 10,
          duration_seconds: 100
        })

      assert playback_events(user, "finished") == []

      {:ok, _} = Playback.mark_watched(user.id, episode_id: episode.id)

      assert [event] = playback_events(user, "finished")
      assert event.resource_type == "episode"
      assert event.resource_id == episode.id
      assert event.metadata["origin"] == "player"
    end

    test "origin option is carried into the emitted event",
         %{user: user, media_item: media_item} do
      {:ok, _} =
        Playback.save_progress(
          user.id,
          [media_item_id: media_item.id],
          %{position_seconds: 0, duration_seconds: 1, watched: true},
          origin: "sync:plex"
        )

      assert [event] = playback_events(user, "finished")
      assert event.metadata["origin"] == "sync:plex"
    end
  end

  describe "completion percentage clamping" do
    setup do
      {:ok, user} = create_user()
      {:ok, media_item} = create_media_item()
      %{user: user, media_item: media_item}
    end

    test "caps percentage at 100 when position exceeds duration", %{
      user: user,
      media_item: media_item
    } do
      # A cold HLS play can post a position beyond the partial duration the
      # player knew at the time. Without a cap this stores e.g. 340% and the
      # UI renders a nonsense progress bar.
      {:ok, progress} =
        Playback.save_progress(user.id, [media_item_id: media_item.id], %{
          position_seconds: 3400,
          duration_seconds: 1000
        })

      assert progress.completion_percentage == 100.0
    end

    test "leaves a normal percentage untouched", %{
      user: user,
      media_item: media_item
    } do
      {:ok, progress} =
        Playback.save_progress(user.id, [media_item_id: media_item.id], %{
          position_seconds: 250,
          duration_seconds: 1000
        })

      assert progress.completion_percentage == 25.0
    end
  end

  defp create_user do
    Accounts.create_user(%{
      email: "user#{System.unique_integer([:positive])}@example.com",
      username: "user#{System.unique_integer([:positive])}",
      password: "password123",
      role: "user"
    })
  end

  defp create_media_item do
    Media.create_media_item(Scope.unrestricted(), %{
      title: "Test Movie #{System.unique_integer([:positive])}",
      tmdb_id: System.unique_integer([:positive]),
      type: "movie",
      year: 2024,
      monitored: true
    })
  end

  defp create_episode do
    {:ok, media_item} =
      Media.create_media_item(
        Scope.unrestricted(),
        %{
          title: "Test Show #{System.unique_integer([:positive])}",
          tmdb_id: System.unique_integer([:positive]),
          type: "tv_show",
          monitored: true
        },
        skip_episode_refresh: true
      )

    Media.create_episode(%{
      media_item_id: media_item.id,
      season_number: 1,
      episode_number: 1,
      title: "Pilot",
      monitored: true
    })
  end

  defp create_show do
    Media.create_media_item(
      Scope.unrestricted(),
      %{
        title: "Test Show #{System.unique_integer([:positive])}",
        tmdb_id: System.unique_integer([:positive]),
        type: "tv_show",
        monitored: true
      },
      skip_episode_refresh: true
    )
  end

  defp create_episode_in(show, season_number, episode_number) do
    {:ok, episode} =
      Media.create_episode(%{
        media_item_id: show.id,
        season_number: season_number,
        episode_number: episode_number,
        title: "S#{season_number}E#{episode_number}",
        monitored: true
      })

    episode
  end
end
