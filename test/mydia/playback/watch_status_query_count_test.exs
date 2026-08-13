defmodule Mydia.Playback.WatchStatusQueryCountTest do
  # Deliberately synchronous, and deliberately in its own file, for exactly the
  # reason spelled out at the top of on_deck_query_count_test.exs: the
  # `:telemetry` handler this test attaches is global to the VM, so running
  # async alongside the rest of the suite counts other modules' queries too.
  use Mydia.DataCase, async: false

  alias Mydia.AccountsFixtures
  alias Mydia.MediaFixtures
  alias Mydia.Playback.WatchStatus

  setup do
    %{user: AccountsFixtures.user_fixture()}
  end

  defp show_with_episodes(count, title) do
    show = MediaFixtures.media_item_fixture(%{type: "tv_show", title: title})

    for n <- 1..count do
      episode =
        MediaFixtures.episode_fixture(%{
          media_item_id: show.id,
          season_number: 1,
          episode_number: n
        })

      MediaFixtures.media_file_fixture(%{episode_id: episode.id})
    end

    show
  end

  defp count_queries(fun) do
    ref = make_ref()
    parent = self()

    handler = fn _event, _measurements, _metadata, _config ->
      send(parent, {ref, :query})
    end

    :telemetry.attach(
      "watch-status-query-count-#{inspect(ref)}",
      [:mydia, :repo, :query],
      handler,
      nil
    )

    fun.()

    :telemetry.detach("watch-status-query-count-#{inspect(ref)}")

    drain = fn drain ->
      receive do
        {^ref, :query} -> 1 + drain.(drain)
      after
        0 -> 0
      end
    end

    drain.(drain)
  end

  describe "load_shows/2 query count" do
    test "the query count does not grow with the number of shows", ctx do
      small_ids = for n <- 1..3, do: show_with_episodes(2, "Small #{n}").id
      small = count_queries(fn -> WatchStatus.load_shows(ctx.user.id, small_ids) end)

      large_ids = small_ids ++ for(n <- 4..15, do: show_with_episodes(2, "Large #{n}").id)
      large = count_queries(fn -> WatchStatus.load_shows(ctx.user.id, large_ids) end)

      assert small == large,
             "expected a constant query count, got #{small} for 3 shows and #{large} for 15"
    end
  end
end
