defmodule Mydia.Media.ContentRatingAgeTest do
  use Mydia.DataCase, async: true

  alias Mydia.Media
  alias Mydia.Media.MediaItem
  alias Mydia.Metadata.Structs.MediaMetadata
  alias Mydia.Repo

  defp create_with_rating(rating) do
    {:ok, item} =
      Media.create_media_item(
        %{
          type: "movie",
          title: "Rated #{System.unique_integer([:positive])}",
          year: 2024,
          metadata: %MediaMetadata{
            provider_id: "1",
            provider: :metadata_relay,
            media_type: :movie,
            content_rating: rating
          }
        },
        skip_episode_refresh: true
      )

    Repo.get!(MediaItem, item.id)
  end

  test "derives the age from the metadata content rating on insert" do
    assert create_with_rating("PG-13").content_rating_age == 13
  end

  test "stores nil when the rating is unrecognized" do
    assert create_with_rating("NOT RATED").content_rating_age == nil
  end

  test "stores nil when there is no rating at all" do
    assert create_with_rating(nil).content_rating_age == nil
  end

  test "recomputes the age when metadata is replaced" do
    item = create_with_rating("G")
    assert item.content_rating_age == 0

    {:ok, updated} =
      Media.update_media_item(item, %{
        metadata: %MediaMetadata{
          provider_id: "1",
          provider: :metadata_relay,
          media_type: :movie,
          content_rating: "R"
        }
      })

    assert Repo.get!(MediaItem, updated.id).content_rating_age == 17
  end

  test "leaves the age alone when a write does not touch metadata" do
    item = create_with_rating("PG-13")
    {:ok, updated} = Media.update_media_item(item, %{monitored: false})

    assert Repo.get!(MediaItem, updated.id).content_rating_age == 13
  end
end
