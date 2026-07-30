defmodule Mydia.LibrarySearchEpisodesTest do
  use Mydia.DataCase

  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures

  alias Mydia.LibrarySearch
  alias Mydia.LibrarySearch.Result

  setup do
    %{user: user_fixture()}
  end

  defp episode_section(results) do
    Enum.find(results.sections, &(&1.type == :episode))
  end

  test "matches an episode by title and carries its show context", %{user: user} do
    show =
      media_item_fixture(%{
        type: "tv_show",
        title: "Alien Nation",
        metadata: %{poster_path: "/show.jpg", backdrop_path: "/showdrop.jpg"}
      })

    episode_fixture(%{
      media_item_id: show.id,
      season_number: 1,
      episode_number: 3,
      title: "Fountain of Youth",
      metadata: %{still_path: "/still.jpg"}
    })

    {:ok, results} = LibrarySearch.search(user, "fountain")

    assert [
             %Result{
               type: :episode,
               title: "Fountain of Youth",
               subtitle: "Alien Nation",
               season_number: 1,
               episode_number: 3,
               parent_id: parent_id,
               still_path: "/still.jpg",
               poster_path: "/show.jpg",
               backdrop_path: "/showdrop.jpg",
               year: nil
             }
           ] = episode_section(results).results

    assert parent_id == show.id
  end

  test "matches episodes with tokens in any order", %{user: user} do
    show = media_item_fixture(%{type: "tv_show", title: "FROM"})

    episode_fixture(%{
      media_item_id: show.id,
      season_number: 1,
      episode_number: 1,
      title: "Long Day's Journey Into Night"
    })

    {:ok, results} = LibrarySearch.search(user, "night journey")

    assert [%Result{title: "Long Day's Journey Into Night"}] = episode_section(results).results
  end

  test "ranks episode titles on the same four tiers", %{user: user} do
    show = media_item_fixture(%{type: "tv_show", title: "Anthology"})

    for {season, number, title} <- [
          {1, 1, "zzz Prepilot"},
          {1, 2, "yyy The Pilot Show"},
          {1, 3, "Pilots of Fortune"},
          {1, 4, "pilot"}
        ] do
      episode_fixture(%{
        media_item_id: show.id,
        season_number: season,
        episode_number: number,
        title: title
      })
    end

    {:ok, results} = LibrarySearch.search(user, "pilot")

    section = episode_section(results)

    assert Enum.map(section.results, & &1.title) == [
             "pilot",
             "Pilots of Fortune",
             "yyy The Pilot Show",
             "zzz Prepilot"
           ]

    assert Enum.map(section.results, & &1.score) == [100.0, 75.0, 50.0, 25.0]
  end

  test "caps episodes at the limit but reports the true total", %{user: user} do
    show = media_item_fixture(%{type: "tv_show", title: "Anthology"})

    for n <- 1..25 do
      episode_fixture(%{
        media_item_id: show.id,
        season_number: 1,
        episode_number: n,
        title: "Alien Part #{String.pad_leading("#{n}", 2, "0")}"
      })
    end

    {:ok, results} = LibrarySearch.search(user, "alien", types: [:episode], limit: 5)

    section = episode_section(results)
    assert length(section.results) == 5
    assert section.total_count == 25
  end

  test "total_count is the same true count regardless of how the limit caps results", %{
    user: user
  } do
    show = media_item_fixture(%{type: "tv_show", title: "Anthology"})

    for n <- 1..7 do
      episode_fixture(%{
        media_item_id: show.id,
        season_number: 1,
        episode_number: n,
        title: "Alien Part #{n}"
      })
    end

    {:ok, capped} = LibrarySearch.search(user, "alien", types: [:episode], limit: 3)
    {:ok, uncapped} = LibrarySearch.search(user, "alien", types: [:episode], limit: 100)

    capped_section = episode_section(capped)
    uncapped_section = episode_section(uncapped)

    # The count query and the row query must derive from the same underlying
    # set of matching rows: capping the page must never change how many rows
    # are reported as matching, and raising the limit past the true total
    # must return every row `total_count` promised, no more and no fewer.
    assert length(capped_section.results) == 3
    assert capped_section.total_count == 7
    assert length(uncapped_section.results) == 7
    assert uncapped_section.total_count == 7
  end

  test "omits the episode section when nothing matches", %{user: user} do
    media_item_fixture(%{type: "movie", title: "Alien"})

    {:ok, results} = LibrarySearch.search(user, "alien")

    assert episode_section(results) == nil
  end

  test "an episode with no metadata still returns a result", %{user: user} do
    show = media_item_fixture(%{type: "tv_show", title: "Anthology"})

    episode_fixture(%{
      media_item_id: show.id,
      season_number: 1,
      episode_number: 1,
      title: "Alien"
    })

    {:ok, results} = LibrarySearch.search(user, "alien", types: [:episode])

    assert [%Result{title: "Alien", still_path: nil}] = episode_section(results).results
  end
end
