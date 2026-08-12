defmodule Mydia.Playback.OnDeckTest do
  use Mydia.DataCase, async: true

  alias Mydia.AccountsFixtures
  alias Mydia.MediaFixtures
  alias Mydia.Playback
  alias Mydia.Playback.{OnDeck, OnDeckEntry}

  setup do
    %{user: AccountsFixtures.user_fixture()}
  end

  # A show with `count` episodes in season 1, each with an untrashed file.
  defp show_with_episodes(count, title \\ nil) do
    show =
      MediaFixtures.media_item_fixture(%{
        type: "tv_show",
        title: title || "Show #{System.unique_integer([:positive])}"
      })

    episodes =
      for n <- 1..count do
        episode =
          MediaFixtures.episode_fixture(%{
            media_item_id: show.id,
            season_number: 1,
            episode_number: n
          })

        MediaFixtures.media_file_fixture(%{episode_id: episode.id})
        episode
      end

    {show, episodes}
  end

  defp watch(user, episode, at) do
    {:ok, progress} =
      Playback.save_progress(
        user.id,
        [episode_id: episode.id],
        %{
          position_seconds: 2400,
          duration_seconds: 2400,
          watched: true,
          last_watched_at: at
        }
      )

    progress
  end

  defp start_watching(user, episode, position, at) do
    {:ok, progress} =
      Playback.save_progress(
        user.id,
        [episode_id: episode.id],
        %{position_seconds: position, duration_seconds: 2400, last_watched_at: at}
      )

    progress
  end

  defp now, do: ~U[2026-08-12 20:00:00Z]
  defp ago(seconds), do: DateTime.add(now(), -seconds, :second)
  defp days_ago(days), do: DateTime.add(now(), -days, :day)

  describe "list/2 next episode" do
    test "finishing an episode surfaces the next one", ctx do
      {_show, [e1, e2, _e3]} = show_with_episodes(3)
      watch(ctx.user, e1, ago(60))

      assert [entry] = OnDeck.list(ctx.user.id, now: now())
      assert entry.kind == :episode
      assert entry.state == :next
      assert entry.episode.id == e2.id
      assert entry.progress == nil
    end

    test "a partially watched episode is a continue entry", ctx do
      {_show, [e1, _e2, _e3]} = show_with_episodes(3)
      start_watching(ctx.user, e1, 600, ago(60))

      assert [entry] = OnDeck.list(ctx.user.id, now: now())
      assert entry.state == :continue
      assert entry.episode.id == e1.id
      assert entry.progress.position_seconds == 600
    end

    test "a fully watched show produces no entry", ctx do
      {_show, episodes} = show_with_episodes(2)
      Enum.each(episodes, &watch(ctx.user, &1, ago(60)))

      assert [] = OnDeck.list(ctx.user.id, now: now())
    end

    test "carries the episode's untrashed files on the entry", ctx do
      {_show, [e1, e2, _e3]} = show_with_episodes(3)
      watch(ctx.user, e1, ago(60))

      assert [entry] = OnDeck.list(ctx.user.id, now: now())
      assert entry.episode.id == e2.id
      assert length(entry.files) == 1
    end
  end

  describe "list/2 engagement" do
    test "a never-started show produces no entry", ctx do
      show_with_episodes(3)

      assert [] = OnDeck.list(ctx.user.id, now: now())
    end

    test "a tap under the position floor does not create engagement", ctx do
      {_show, [e1, _e2, _e3]} = show_with_episodes(3)
      start_watching(ctx.user, e1, 73, ago(60))

      assert [] = OnDeck.list(ctx.user.id, now: now())
    end

    test "a tap at or above the position floor does create engagement", ctx do
      {_show, [e1, _e2, _e3]} = show_with_episodes(3)
      start_watching(ctx.user, e1, 120, ago(60))

      assert [entry] = OnDeck.list(ctx.user.id, now: now())
      assert entry.episode.id == e1.id
    end

    test "a synced watched row with position 0 still creates engagement", ctx do
      {_show, [e1, e2, _e3]} = show_with_episodes(3)

      {:ok, _} =
        Playback.save_progress(
          ctx.user.id,
          [episode_id: e1.id],
          %{
            position_seconds: 0,
            duration_seconds: 1,
            watched: true,
            last_watched_at: ago(60)
          },
          authoritative_watched: true
        )

      assert [entry] = OnDeck.list(ctx.user.id, now: now())
      assert entry.state == :next
      assert entry.episode.id == e2.id
    end

    test "the position floor is configurable", ctx do
      {_show, [e1, _e2, _e3]} = show_with_episodes(3)
      start_watching(ctx.user, e1, 73, ago(60))

      assert [] = OnDeck.list(ctx.user.id, now: now())
      assert [_entry] = OnDeck.list(ctx.user.id, now: now(), min_position_seconds: 60)
    end
  end

  describe "list/2 age cutoff" do
    test "a row older than the cutoff drops out", ctx do
      {_show, [e1, _e2, _e3]} = show_with_episodes(3)
      watch(ctx.user, e1, days_ago(120))

      assert [] = OnDeck.list(ctx.user.id, now: now())
    end

    test "the same row inside the window does not drop out", ctx do
      {_show, [e1, _e2, _e3]} = show_with_episodes(3)
      watch(ctx.user, e1, days_ago(30))

      assert [_entry] = OnDeck.list(ctx.user.id, now: now())
    end

    test "history outside the cutoff still informs which episode is next", ctx do
      {_show, [e1, e2, e3]} = show_with_episodes(3)
      # Season watched long ago, then one episode watched recently.
      watch(ctx.user, e1, days_ago(300))
      watch(ctx.user, e2, ago(60))

      assert [entry] = OnDeck.list(ctx.user.id, now: now())
      assert entry.episode.id == e3.id
      assert entry.state == :next
    end
  end

  describe "list/2 one card per show" do
    test "several in-progress episodes still yield exactly one entry", ctx do
      {_show, [e1, e2, e3]} = show_with_episodes(3)
      start_watching(ctx.user, e1, 600, ago(300))
      start_watching(ctx.user, e2, 600, ago(200))
      start_watching(ctx.user, e3, 600, ago(100))

      assert [entry] = OnDeck.list(ctx.user.id, now: now())
      # The earliest in series order is what you would actually play next.
      assert entry.episode.id == e1.id
    end
  end

  describe "list/2 movies" do
    test "an in-progress movie appears", ctx do
      movie = MediaFixtures.media_item_fixture(%{type: "movie"})
      MediaFixtures.media_file_fixture(%{media_item_id: movie.id})

      {:ok, _} =
        Playback.save_progress(
          ctx.user.id,
          [media_item_id: movie.id],
          %{position_seconds: 900, duration_seconds: 7200, last_watched_at: ago(60)}
        )

      assert [entry] = OnDeck.list(ctx.user.id, now: now())
      assert entry.kind == :movie
      assert entry.state == :continue
      assert entry.media_item.id == movie.id
      assert length(entry.files) == 1
    end

    test "a movie with no file is skipped", ctx do
      movie = MediaFixtures.media_item_fixture(%{type: "movie"})

      {:ok, _} =
        Playback.save_progress(
          ctx.user.id,
          [media_item_id: movie.id],
          %{position_seconds: 900, duration_seconds: 7200, last_watched_at: ago(60)}
        )

      assert [] = OnDeck.list(ctx.user.id, now: now())
    end

    test "a watched movie is skipped", ctx do
      movie = MediaFixtures.media_item_fixture(%{type: "movie"})
      MediaFixtures.media_file_fixture(%{media_item_id: movie.id})

      {:ok, _} =
        Playback.save_progress(
          ctx.user.id,
          [media_item_id: movie.id],
          %{
            position_seconds: 7000,
            duration_seconds: 7200,
            last_watched_at: ago(60)
          }
        )

      assert [] = OnDeck.list(ctx.user.id, now: now())
    end
  end

  describe "list/2 ordering" do
    test "the most recently watched show sorts first", ctx do
      {_a, [a1, _a2]} = show_with_episodes(2, "Alpha")
      {_b, [b1, _b2]} = show_with_episodes(2, "Bravo")
      {_c, [c1, _c2]} = show_with_episodes(2, "Charlie")

      watch(ctx.user, a1, ago(3000))
      watch(ctx.user, c1, ago(60))
      watch(ctx.user, b1, ago(1500))

      titles = ctx.user.id |> OnDeck.list(now: now()) |> Enum.map(& &1.show.title)

      assert titles == ["Charlie", "Bravo", "Alpha"]
    end

    test "movies and episodes interleave by recency", ctx do
      {_show, [e1, _e2]} = show_with_episodes(2, "Alpha")
      movie = MediaFixtures.media_item_fixture(%{type: "movie", title: "Some Movie"})
      MediaFixtures.media_file_fixture(%{media_item_id: movie.id})

      watch(ctx.user, e1, ago(3000))

      {:ok, _} =
        Playback.save_progress(
          ctx.user.id,
          [media_item_id: movie.id],
          %{position_seconds: 900, duration_seconds: 7200, last_watched_at: ago(60)}
        )

      assert [first, second] = OnDeck.list(ctx.user.id, now: now())
      assert first.kind == :movie
      assert second.kind == :episode
    end

    test "the limit applies after sorting, not before", ctx do
      # The production bug: the show just watched was at index 37 of 43 in an
      # unordered list and was truncated away by a limit of 10.
      for n <- 1..12 do
        {_show, [e1, _e2]} = show_with_episodes(2, "Filler #{n}")
        watch(ctx.user, e1, ago(10_000 + n))
      end

      {_target, [t1, t2]} = show_with_episodes(2, "Just Watched")
      watch(ctx.user, t1, ago(60))

      entries = OnDeck.list(ctx.user.id, now: now(), limit: 10)

      assert length(entries) == 10
      assert hd(entries).episode.id == t2.id
      assert hd(entries).show.title == "Just Watched"
    end
  end

  describe "list/2 isolation" do
    test "another user's progress does not leak in", ctx do
      other = AccountsFixtures.user_fixture()
      {_show, [e1, _e2]} = show_with_episodes(2)
      watch(other, e1, ago(60))

      assert [] = OnDeck.list(ctx.user.id, now: now())
      assert [_entry] = OnDeck.list(other.id, now: now())
    end
  end

  describe "id/1" do
    test "uses the episode id for an episode entry", ctx do
      {_show, [e1, e2, _e3]} = show_with_episodes(3)
      watch(ctx.user, e1, ago(60))

      assert [entry] = OnDeck.list(ctx.user.id, now: now())
      assert OnDeckEntry.id(entry) == e2.id
    end
  end
end
