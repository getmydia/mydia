defmodule Mydia.Media.RestrictionsTest do
  use Mydia.DataCase, async: true

  import Ecto.Query
  import Mydia.AccountsFixtures

  alias Mydia.Accounts.Scope
  alias Mydia.Media
  alias Mydia.Media.Episode
  alias Mydia.Media.MediaItem
  alias Mydia.Media.Restrictions
  alias Mydia.Metadata.Structs.MediaMetadata
  alias Mydia.Repo

  defp item(attrs) do
    {:ok, item} =
      Enum.into(attrs, %{
        type: "movie",
        title: "Item #{System.unique_integer([:positive])}",
        year: 2024
      })
      |> Media.create_media_item(skip_episode_refresh: true)

    item
  end

  defp categorized(category, rating) do
    item =
      item(%{
        metadata: %MediaMetadata{
          provider_id: to_string(System.unique_integer([:positive])),
          provider: :metadata_relay,
          media_type: :movie,
          content_rating: rating
        }
      })

    Repo.update_all(from(m in MediaItem, where: m.id == ^item.id),
      set: [category: to_string(category)]
    )

    Repo.get!(MediaItem, item.id)
  end

  defp titles(scope) do
    MediaItem
    |> Restrictions.apply(scope)
    |> select([m], m.id)
    |> Repo.all()
    |> MapSet.new()
  end

  describe "apply/2 with no restrictions" do
    test "returns everything" do
      cartoon = categorized(:cartoon_movie, "G")
      thriller = categorized(:movie, "R")

      ids = titles(Scope.unrestricted())

      assert MapSet.member?(ids, cartoon.id)
      assert MapSet.member?(ids, thriller.id)
    end
  end

  describe "apply/2 with a category limit" do
    test "keeps only the allowed categories" do
      cartoon = categorized(:cartoon_movie, "G")
      thriller = categorized(:movie, "R")

      scope = Scope.for_user(restricted_user_fixture(%{allowed_categories: ["cartoon_movie"]}))
      ids = titles(scope)

      assert MapSet.member?(ids, cartoon.id)
      refute MapSet.member?(ids, thriller.id)
    end

    test "hides an item whose category has never been classified" do
      unclassified = item(%{})
      Repo.update_all(from(m in MediaItem, where: m.id == ^unclassified.id), set: [category: nil])

      scope = Scope.for_user(restricted_user_fixture(%{allowed_categories: ["cartoon_movie"]}))

      refute MapSet.member?(titles(scope), unclassified.id)
    end
  end

  describe "apply/2 with an age limit" do
    test "keeps items at or below the limit" do
      g_rated = categorized(:cartoon_movie, "G")
      pg13 = categorized(:movie, "PG-13")

      scope = Scope.for_user(restricted_user_fixture(%{max_content_age: 12}))
      ids = titles(scope)

      assert MapSet.member?(ids, g_rated.id)
      refute MapSet.member?(ids, pg13.id)
    end

    test "hides unrated items, because an unknown rating is not a safe one" do
      unrated = categorized(:cartoon_movie, nil)

      scope = Scope.for_user(restricted_user_fixture(%{max_content_age: 18}))

      refute MapSet.member?(titles(scope), unrated.id)
    end

    test "shows unrated items when there is no limit at all" do
      unrated = categorized(:cartoon_movie, nil)

      scope = Scope.for_user(restricted_user_fixture(%{allowed_categories: ["cartoon_movie"]}))

      assert MapSet.member?(titles(scope), unrated.id)
    end
  end

  describe "apply/2 with both limits" do
    test "an item must satisfy every dimension" do
      allowed = categorized(:cartoon_movie, "G")
      wrong_category = categorized(:movie, "G")
      too_old = categorized(:cartoon_movie, "R")

      scope =
        Scope.for_user(
          restricted_user_fixture(%{allowed_categories: ["cartoon_movie"], max_content_age: 7})
        )

      ids = titles(scope)

      assert MapSet.member?(ids, allowed.id)
      refute MapSet.member?(ids, wrong_category.id)
      refute MapSet.member?(ids, too_old.id)
    end
  end

  describe "apply_to_episodes/2" do
    test "an episode is visible exactly when its show is" do
      show = categorized(:cartoon_series, "TV-Y")
      Repo.update_all(from(m in MediaItem, where: m.id == ^show.id), set: [type: "tv_show"])

      {:ok, episode} =
        Media.create_episode(%{
          media_item_id: show.id,
          season_number: 1,
          episode_number: 1,
          title: "Pilot"
        })

      allowed = Scope.for_user(restricted_user_fixture(%{allowed_categories: ["cartoon_series"]}))
      denied = Scope.for_user(restricted_user_fixture(%{allowed_categories: ["cartoon_movie"]}))

      assert [_] = Episode |> Restrictions.apply_to_episodes(allowed) |> Repo.all()
      assert [] = Episode |> Restrictions.apply_to_episodes(denied) |> Repo.all()
      assert episode.id
    end
  end

  describe "visible?/2" do
    test "agrees with the query for an allowed item" do
      cartoon = categorized(:cartoon_movie, "G")
      scope = Scope.for_user(restricted_user_fixture(%{allowed_categories: ["cartoon_movie"]}))

      assert Restrictions.visible?(cartoon, scope)
    end

    test "agrees with the query for a denied item" do
      thriller = categorized(:movie, "R")
      scope = Scope.for_user(restricted_user_fixture(%{allowed_categories: ["cartoon_movie"]}))

      refute Restrictions.visible?(thriller, scope)
    end
  end
end
