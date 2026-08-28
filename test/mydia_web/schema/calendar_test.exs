defmodule MydiaWeb.Schema.CalendarTest do
  use MydiaWeb.ConnCase

  alias Mydia.AccountsFixtures
  alias Mydia.MediaFixtures

  @query """
  query Calendar($start: Date!, $end: Date!) {
    calendar(start: $start, end: $end) {
      id
      kind
      airDate
      title
      seasonNumber
      episodeNumber
      mediaItemId
      mediaItemTitle
      artwork { posterUrl }
      files { id }
    }
  }
  """

  @vars %{"start" => "2026-08-01", "end" => "2026-08-31"}

  setup do
    %{user: AccountsFixtures.user_fixture()}
  end

  test "returns episodes and movies inside the window", ctx do
    show = MediaFixtures.media_item_fixture(%{type: "tv_show", title: "A Show"})

    episode =
      MediaFixtures.episode_fixture(%{
        media_item_id: show.id,
        season_number: 3,
        episode_number: 4,
        title: "An Episode",
        air_date: ~D[2026-08-15]
      })

    MediaFixtures.media_file_fixture(%{episode_id: episode.id})

    assert {:ok, %{data: %{"calendar" => [entry]}}} = run_query(@query, @vars, ctx.user)

    assert entry["kind"] == "EPISODE"
    assert entry["airDate"] == "2026-08-15"
    assert entry["title"] == "An Episode"
    assert entry["seasonNumber"] == 3
    assert entry["episodeNumber"] == 4
    assert entry["mediaItemId"] == show.id
    assert entry["mediaItemTitle"] == "A Show"
    assert length(entry["files"]) == 1
  end

  test "an entry with no file comes back with an empty files list", ctx do
    show = MediaFixtures.media_item_fixture(%{type: "tv_show", title: "Fileless"})

    MediaFixtures.episode_fixture(%{
      media_item_id: show.id,
      season_number: 1,
      episode_number: 1,
      air_date: ~D[2026-08-10]
    })

    assert {:ok, %{data: %{"calendar" => [entry]}}} = run_query(@query, @vars, ctx.user)
    assert entry["files"] == []
  end

  test "an entry whose only file is trashed comes back with an empty files list", ctx do
    show = MediaFixtures.media_item_fixture(%{type: "tv_show", title: "Trashed Only"})

    episode =
      MediaFixtures.episode_fixture(%{
        media_item_id: show.id,
        season_number: 1,
        episode_number: 1,
        air_date: ~D[2026-08-10]
      })

    MediaFixtures.media_file_fixture(%{
      episode_id: episode.id,
      trashed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })

    assert {:ok, %{data: %{"calendar" => [entry]}}} = run_query(@query, @vars, ctx.user)
    assert entry["files"] == []
  end

  test "excludes entries outside the window, bounds included", ctx do
    show = MediaFixtures.media_item_fixture(%{type: "tv_show", title: "Edges"})

    for {season, episode, date} <- [
          {1, 1, ~D[2026-07-31]},
          {1, 2, ~D[2026-08-01]},
          {1, 3, ~D[2026-08-31]},
          {1, 4, ~D[2026-09-01]}
        ] do
      MediaFixtures.episode_fixture(%{
        media_item_id: show.id,
        season_number: season,
        episode_number: episode,
        air_date: date
      })
    end

    assert {:ok, %{data: %{"calendar" => entries}}} = run_query(@query, @vars, ctx.user)
    assert Enum.map(entries, & &1["airDate"]) == ["2026-08-01", "2026-08-31"]
  end

  test "orders by air date, then playable first, then title", ctx do
    # Widened beyond @vars on purpose: the July/September entries below only
    # catch a regression to day-only date comparison if they land on
    # opposite sides of a month boundary while still both being in-window.
    vars = %{"start" => "2026-07-01", "end" => "2026-09-30"}

    show = MediaFixtures.media_item_fixture(%{type: "tv_show", title: "Zebra Show"})
    other = MediaFixtures.media_item_fixture(%{type: "tv_show", title: "Alpha Show"})

    playable =
      MediaFixtures.episode_fixture(%{
        media_item_id: show.id,
        season_number: 1,
        episode_number: 1,
        air_date: ~D[2026-08-10]
      })

    MediaFixtures.media_file_fixture(%{episode_id: playable.id})

    MediaFixtures.episode_fixture(%{
      media_item_id: other.id,
      season_number: 1,
      episode_number: 1,
      air_date: ~D[2026-08-10]
    })

    # A `%Date{}` compared as a bare tuple element sorts by struct field
    # order (day, then month, then year), which would put 2026-07-31 AFTER
    # 2026-08-10 and 2026-09-01. These two entries fail under that bug and
    # pass only when the sort compares dates chronologically.
    MediaFixtures.episode_fixture(%{
      media_item_id: show.id,
      season_number: 1,
      episode_number: 2,
      air_date: ~D[2026-07-31]
    })

    MediaFixtures.episode_fixture(%{
      media_item_id: other.id,
      season_number: 1,
      episode_number: 2,
      air_date: ~D[2026-09-01]
    })

    assert {:ok, %{data: %{"calendar" => entries}}} = run_query(@query, vars, ctx.user)

    assert Enum.map(entries, &{&1["airDate"], &1["mediaItemTitle"]}) == [
             {"2026-07-31", "Zebra Show"},
             {"2026-08-10", "Zebra Show"},
             {"2026-08-10", "Alpha Show"},
             {"2026-09-01", "Alpha Show"}
           ]
  end

  test "never exposes download state", ctx do
    show = MediaFixtures.media_item_fixture(%{type: "tv_show", title: "No Leaks"})

    MediaFixtures.episode_fixture(%{
      media_item_id: show.id,
      season_number: 1,
      episode_number: 1,
      air_date: ~D[2026-08-05]
    })

    leaky = """
    query Calendar($start: Date!, $end: Date!) {
      calendar(start: $start, end: $end) { hasDownloads }
    }
    """

    assert {:ok, %{errors: [%{message: message}]}} = run_query(leaky, @vars, ctx.user)
    assert message =~ "Cannot query field"
  end

  test "requires an authenticated user" do
    assert {:ok, %{errors: [_ | _]}} = run_query(@query, @vars, nil)
  end

  describe "files query count" do
    # `files` used to be a per-entry field resolver, so a response with N
    # playable entries issued N extra `Repo.all` calls (one per entry) on top
    # of the two list queries. This pins the fix: the query count must stay
    # flat as the number of playable entries grows, and every entry's `files`
    # must still come back correct once batched.
    #
    # Counting queries via a `:telemetry` handler on `[:mydia, :repo, :query]`
    # only measures this test in isolation because `MydiaWeb.ConnCase` tests
    # default to `async: false` (no `async: true` was passed when this module
    # called `use MydiaWeb.ConnCase`), so ExUnit never runs this module's
    # tests concurrently with another test module's queries.
    test "does not grow with the number of playable entries", ctx do
      count_queries = fn fun ->
        ref = make_ref()
        parent = self()

        handler = fn _event, _measurements, _metadata, _config ->
          send(parent, {ref, :query})
        end

        :telemetry.attach(
          "calendar-files-query-count-#{inspect(ref)}",
          [:mydia, :repo, :query],
          handler,
          nil
        )

        fun.()

        :telemetry.detach("calendar-files-query-count-#{inspect(ref)}")

        count_messages = fn count_messages ->
          receive do
            {^ref, :query} -> 1 + count_messages.(count_messages)
          after
            0 -> 0
          end
        end

        count_messages.(count_messages)
      end

      # A show with `episode_count` playable episodes, plus one playable
      # movie, all inside `@vars`'s window.
      build_playable_entries = fn episode_count, label ->
        show = MediaFixtures.media_item_fixture(%{type: "tv_show", title: "Show #{label}"})

        for n <- 1..episode_count do
          episode =
            MediaFixtures.episode_fixture(%{
              media_item_id: show.id,
              season_number: 1,
              episode_number: n,
              air_date: ~D[2026-08-10]
            })

          MediaFixtures.media_file_fixture(%{episode_id: episode.id})
        end

        movie =
          MediaFixtures.media_item_fixture(%{
            type: "movie",
            title: "Movie #{label}",
            metadata: %{
              provider_id: "movie-#{label}",
              provider: :metadata_relay,
              media_type: :movie,
              release_date: ~D[2026-08-20]
            }
          })

        MediaFixtures.media_file_fixture(%{media_item_id: movie.id})
      end

      build_playable_entries.(3, "small")

      small =
        count_queries.(fn ->
          assert {:ok, %{data: %{"calendar" => entries}}} = run_query(@query, @vars, ctx.user)
          assert length(entries) == 4
          assert Enum.all?(entries, &(length(&1["files"]) == 1))
        end)

      build_playable_entries.(20, "large")

      large =
        count_queries.(fn ->
          assert {:ok, %{data: %{"calendar" => entries}}} = run_query(@query, @vars, ctx.user)
          assert length(entries) == 25
          assert Enum.all?(entries, &(length(&1["files"]) == 1))
        end)

      assert small == large,
             "expected a constant query count, got #{small} for 4 entries and #{large} for 25"
    end
  end

  defp run_query(query, variables, user) do
    context = if user, do: %{current_user: user}, else: %{}
    Absinthe.run(query, MydiaWeb.Schema, variables: variables, context: context)
  end
end
