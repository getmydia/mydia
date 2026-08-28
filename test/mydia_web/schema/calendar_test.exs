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

  defp run_query(query, variables, user) do
    context = if user, do: %{current_user: user}, else: %{}
    Absinthe.run(query, MydiaWeb.Schema, variables: variables, context: context)
  end
end
