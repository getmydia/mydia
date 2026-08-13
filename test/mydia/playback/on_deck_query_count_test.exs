defmodule Mydia.Playback.OnDeckQueryCountTest do
  # Deliberately synchronous, and deliberately in its own file.
  #
  # This test counts queries by attaching a `:telemetry` handler to
  # `[:mydia, :repo, :query]`. Telemetry handlers are global to the VM, so the
  # handler sees every query issued by every process while it is attached, not
  # just the ones this test causes. Running alongside the other ~280 async test
  # modules, it counted their queries too, which made it fail with counts that
  # went DOWN as the library grew:
  #
  #     expected a constant query count, got 12 for 3 shows and 10 for 15
  #
  # ExUnit runs async modules concurrently and sync modules on their own, so
  # `async: false` is what makes the counter measure only this test. It has to
  # be a separate module because the flag is per-module, and the other OnDeck
  # tests have no reason to give up their concurrency.
  use Mydia.DataCase, async: false

  alias Mydia.AccountsFixtures
  alias Mydia.MediaFixtures
  alias Mydia.Playback
  alias Mydia.Playback.OnDeck

  setup do
    %{user: AccountsFixtures.user_fixture()}
  end

  # A show with `count` episodes in season 1, each with an untrashed file.
  defp show_with_episodes(count, title) do
    show =
      MediaFixtures.media_item_fixture(%{type: "tv_show", title: title})

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

  defp now, do: ~U[2026-08-12 20:00:00Z]
  defp ago(seconds), do: DateTime.add(now(), -seconds, :second)

  describe "list/2 query count" do
    test "the query count does not grow with the number of engaged shows", ctx do
      count_queries = fn fun ->
        ref = make_ref()
        parent = self()

        handler = fn _event, _measurements, _metadata, _config ->
          send(parent, {ref, :query})
        end

        :telemetry.attach(
          "on-deck-query-count-#{inspect(ref)}",
          [:mydia, :repo, :query],
          handler,
          nil
        )

        fun.()

        :telemetry.detach("on-deck-query-count-#{inspect(ref)}")

        count_messages = fn count_messages ->
          receive do
            {^ref, :query} -> 1 + count_messages.(count_messages)
          after
            0 -> 0
          end
        end

        count_messages.(count_messages)
      end

      for n <- 1..3 do
        {_show, [e1, _e2]} = show_with_episodes(2, "Small #{n}")
        watch(ctx.user, e1, ago(100 + n))
      end

      small = count_queries.(fn -> OnDeck.list(ctx.user.id, now: now()) end)

      for n <- 4..15 do
        {_show, [e1, _e2]} = show_with_episodes(2, "Large #{n}")
        watch(ctx.user, e1, ago(100 + n))
      end

      large = count_queries.(fn -> OnDeck.list(ctx.user.id, now: now()) end)

      assert small == large,
             "expected a constant query count, got #{small} for 3 shows and #{large} for 15"

      assert large <= 8, "expected at most 8 queries, got #{large}"
    end
  end
end
