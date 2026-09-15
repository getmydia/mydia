defmodule Mydia.Media.UpdateAuditTest do
  use Mydia.DataCase, async: false

  import Mydia.MediaFixtures

  alias Mydia.{Events, Media}
  alias Mydia.Events.Presentation

  defp updated_events(item) do
    Events.list_events(
      type: "media_item.updated",
      resource_type: "media_item",
      resource_id: item.id
    )
  end

  test "rating drift below display precision records no update" do
    item = media_item_fixture(%{title: "Quiet Tide", metadata: %{vote_average: 7.81}})
    before = length(updated_events(item))

    assert {:ok, _} =
             Media.update_media_item(item, %{metadata: %{vote_average: 7.84}},
               reason: "Metadata refreshed"
             )

    assert length(updated_events(item)) == before
  end

  test "a rating change at display precision is still recorded" do
    item = media_item_fixture(%{title: "Quiet Tide", metadata: %{vote_average: 7.8}})
    before = updated_events(item)

    assert {:ok, _} =
             Media.update_media_item(item, %{metadata: %{vote_average: 7.9}},
               reason: "Metadata refreshed"
             )

    assert [event] = updated_events(item) -- before
    assert Presentation.detail(event) =~ "Rating"
  end
end
