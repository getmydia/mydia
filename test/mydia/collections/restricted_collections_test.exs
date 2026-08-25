defmodule Mydia.Collections.RestrictedCollectionsTest do
  use Mydia.DataCase, async: true

  import Ecto.Query
  import Mydia.AccountsFixtures

  alias Mydia.Accounts.Scope
  alias Mydia.Collections
  alias Mydia.Media
  alias Mydia.Media.MediaItem
  alias Mydia.Metadata.Structs.MediaMetadata
  alias Mydia.Repo

  defp categorized(category, rating) do
    {:ok, item} =
      Media.create_media_item(
        Scope.system(),
        %{
          type: "movie",
          title: "Item #{System.unique_integer([:positive])}",
          year: 2024,
          metadata: %MediaMetadata{
            provider_id: to_string(System.unique_integer([:positive])),
            provider: :metadata_relay,
            media_type: :movie,
            content_rating: rating
          }
        },
        skip_episode_refresh: true
      )

    Repo.update_all(from(m in MediaItem, where: m.id == ^item.id),
      set: [category: to_string(category)]
    )

    Repo.get!(MediaItem, item.id)
  end

  test "a manual collection hides items the scope may not see" do
    owner = user_fixture()
    cartoon = categorized(:cartoon_movie, "G")
    thriller = categorized(:movie, "R")

    {:ok, collection} = Collections.create_collection(owner, %{name: "Mixed", type: "manual"})
    {:ok, _} = Collections.add_item(collection, cartoon.id)
    {:ok, _} = Collections.add_item(collection, thriller.id)

    scope = Scope.for_user(restricted_user_fixture(%{allowed_categories: ["cartoon_movie"]}))
    ids = scope |> Collections.list_collection_items(collection) |> Enum.map(& &1.id)

    assert cartoon.id in ids
    refute thriller.id in ids
  end

  test "an unrestricted scope still sees both" do
    owner = user_fixture()
    cartoon = categorized(:cartoon_movie, "G")
    thriller = categorized(:movie, "R")

    {:ok, collection} = Collections.create_collection(owner, %{name: "Mixed", type: "manual"})
    {:ok, _} = Collections.add_item(collection, cartoon.id)
    {:ok, _} = Collections.add_item(collection, thriller.id)

    ids =
      Scope.unrestricted()
      |> Collections.list_collection_items(collection)
      |> Enum.map(& &1.id)

    assert cartoon.id in ids
    assert thriller.id in ids
  end

  test "favorites do not report a hidden item as favorited" do
    user = restricted_user_fixture(%{allowed_categories: ["cartoon_movie"]})
    thriller = categorized(:movie, "R")

    {:ok, _} = Collections.toggle_favorite(user, thriller.id)

    refute Collections.is_favorite?(Scope.for_user(user), thriller.id)
  end
end
