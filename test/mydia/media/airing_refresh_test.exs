defmodule Mydia.Media.AiringRefreshTest do
  use Mydia.DataCase, async: false

  import Mydia.MediaFixtures

  alias Mydia.Media.AiringRefresh

  @today ~D[2026-09-14]

  defp show(attrs \\ %{}) do
    media_item_fixture(Map.merge(%{type: "tv_show", title: "Lantern Bay", year: 2025}, attrs))
  end

  defp episode(item, attrs) do
    episode_fixture(
      Map.merge(
        %{
          media_item_id: item.id,
          season_number: 1,
          episode_number: System.unique_integer([:positive])
        },
        attrs
      )
    )
  end

  defp complete_metadata(number) do
    %{
      season_number: 1,
      episode_number: number,
      name: "Harbor Lights",
      overview: "The lighthouse keeper finds a letter.",
      still_path: "/still.jpg"
    }
  end

  defp due(scope),
    do:
      Enum.map(AiringRefresh.due_seasons(@today, scope), fn {item, seasons} ->
        {item.id, seasons}
      end)

  test "a placeholder title airing within a day is due in both scopes" do
    item = show()
    episode(item, %{title: "TBA ", air_date: Date.add(@today, 1)})

    assert due(:hot) == [{item.id, [1]}]
    assert due(:all) == [{item.id, [1]}]
  end

  test "a placeholder title airing later in the week is due only in the daily scope" do
    item = show()
    episode(item, %{title: "Episode 8", air_date: Date.add(@today, 5)})

    assert due(:hot) == []
    assert due(:all) == [{item.id, [1]}]
  end

  test "the window runs from 14 days after air to 7 days before" do
    inside = show(%{title: "Inside Show"})
    episode(inside, %{title: "TBA", air_date: Date.add(@today, 7)})
    episode(inside, %{season_number: 2, title: "TBA", air_date: Date.add(@today, -14)})

    outside = show(%{title: "Outside Show"})
    episode(outside, %{title: "TBA", air_date: Date.add(@today, 8)})
    episode(outside, %{season_number: 2, title: "TBA", air_date: Date.add(@today, -15)})

    assert due(:all) == [{inside.id, [1, 2]}]
  end

  test "an aired episode missing its screencap or overview is due, an unaired one is not" do
    aired = show(%{title: "Aired Show"})

    episode(aired, %{
      title: "Harbor Lights",
      air_date: Date.add(@today, -3),
      metadata: %{complete_metadata(1) | still_path: nil}
    })

    placeholder_overview = show(%{title: "Overview Show"})

    episode(placeholder_overview, %{
      title: "Harbor Lights",
      air_date: Date.add(@today, -1),
      metadata: %{complete_metadata(1) | overview: "TBC"}
    })

    unaired = show(%{title: "Unaired Show"})

    episode(unaired, %{
      title: "Harbor Lights",
      air_date: Date.add(@today, 3),
      metadata: %{complete_metadata(1) | still_path: nil, overview: nil}
    })

    assert due(:all) == [{aired.id, [1]}, {placeholder_overview.id, [1]}]
  end

  test "a complete episode is not due" do
    item = show()
    episode(item, %{title: "Harbor Lights", air_date: @today, metadata: complete_metadata(1)})

    assert due(:all) == []
  end

  test "an unmonitored show is never due" do
    item = show(%{monitored: false})
    episode(item, %{title: "TBA", air_date: @today})

    assert due(:all) == []
  end

  test "an episode without an air date is left to the weekly pass" do
    item = show()
    episode(item, %{title: "TBA", air_date: nil})

    assert due(:all) == []
  end
end
