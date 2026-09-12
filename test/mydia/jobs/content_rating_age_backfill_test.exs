defmodule Mydia.Jobs.ContentRatingAgeBackfillTest do
  use Mydia.DataCase, async: true
  use Oban.Testing, repo: Mydia.Repo

  import Ecto.Query

  alias Mydia.Accounts.Scope
  alias Mydia.Jobs.ContentRatingAgeBackfill
  alias Mydia.Media
  alias Mydia.Media.MediaItem
  alias Mydia.Metadata.Structs.MediaMetadata
  alias Mydia.Repo

  defp item_with_rating(rating) do
    {:ok, item} =
      Media.create_media_item(
        Scope.unrestricted(),
        %{
          type: "movie",
          title: "Backfill #{System.unique_integer([:positive])}",
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

    # Clear the derived column so the row looks like one written before the
    # column existed.
    Repo.update_all(from(m in MediaItem, where: m.id == ^item.id),
      set: [content_rating_age: nil]
    )

    item
  end

  test "fills in the age for rows written before the column existed" do
    item = item_with_rating("TV-14")

    assert :ok = perform_job(ContentRatingAgeBackfill, %{})

    assert Repo.get!(MediaItem, item.id).content_rating_age == 14
  end

  test "leaves unrecognized ratings unrated" do
    item = item_with_rating("NOT RATED")

    assert :ok = perform_job(ContentRatingAgeBackfill, %{})

    assert Repo.get!(MediaItem, item.id).content_rating_age == nil
  end

  test "is safe to run twice" do
    item = item_with_rating("G")

    assert :ok = perform_job(ContentRatingAgeBackfill, %{})
    assert :ok = perform_job(ContentRatingAgeBackfill, %{})

    assert Repo.get!(MediaItem, item.id).content_rating_age == 0
  end
end
