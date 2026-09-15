defmodule Mydia.Events.EpisodeTitlesUpdatedTest do
  use Mydia.DataCase, async: false

  import Mydia.MediaFixtures

  alias Mydia.Events

  test "records the full count and at most ten sample changes" do
    item = media_item_fixture(%{type: "tv_show", title: "Lantern Bay"})

    changes =
      for number <- 1..12 do
        %{season: 1, episode: number, old: "TBA ", new: "Chapter #{number}"}
      end

    assert :ok = Events.episode_titles_updated(item, changes, :job, "airing_episode_refresh")

    assert [event] =
             Events.list_events(
               type: "media_item.episode_titles_updated",
               resource_type: "media_item",
               resource_id: item.id
             )

    assert event.category == "media"
    assert event.actor_id == "airing_episode_refresh"
    assert event.metadata["title"] == "Lantern Bay"
    assert event.metadata["media_type"] == "tv_show"
    assert event.metadata["count"] == 12
    assert length(event.metadata["changes"]) == 10

    assert hd(event.metadata["changes"]) == %{
             "season" => 1,
             "episode" => 1,
             "old" => "TBA ",
             "new" => "Chapter 1"
           }
  end
end
