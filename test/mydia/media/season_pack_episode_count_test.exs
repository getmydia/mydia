defmodule Mydia.Media.SeasonPackEpisodeCountTest do
  use Mydia.DataCase, async: true

  import Mydia.MediaFixtures

  alias Mydia.Media

  setup do
    %{show: media_item_fixture(%{type: "tv_show", title: "Kaiju Garden"})}
  end

  test "counts only aired episodes of an airing season", %{show: show} do
    today = Date.utc_today()

    for {number, air_date} <- [
          {1, Date.add(today, -14)},
          {2, Date.add(today, -7)},
          {3, Date.add(today, 7)}
        ] do
      episode_fixture(%{
        media_item_id: show.id,
        season_number: 3,
        episode_number: number,
        air_date: air_date
      })
    end

    assert Media.season_pack_episode_count(show.id, 3) == 2
  end

  test "counts every episode when none carry an air date", %{show: show} do
    for number <- 1..4 do
      episode_fixture(%{media_item_id: show.id, season_number: 2, episode_number: number})
    end

    assert Media.season_pack_episode_count(show.id, 2) == 4
  end

  test "is never below one", %{show: show} do
    assert Media.season_pack_episode_count(show.id, 9) == 1
  end
end
