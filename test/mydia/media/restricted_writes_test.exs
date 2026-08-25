defmodule Mydia.Media.RestrictedWritesTest do
  use Mydia.DataCase, async: true

  import Mydia.AccountsFixtures

  alias Mydia.Accounts.Scope
  alias Mydia.Media
  alias Mydia.Metadata.Structs.MediaMetadata

  defp cartoon_only_scope do
    Scope.for_user(restricted_user_fixture(%{allowed_categories: ["cartoon_movie"]}))
  end

  defp metadata(attrs) do
    struct!(%MediaMetadata{provider_id: "1", provider: :tmdb, media_type: :movie}, attrs)
  end

  test "creating an out-of-bounds item is refused" do
    assert {:error, :restricted} =
             Media.create_media_item(
               cartoon_only_scope(),
               %{
                 type: "movie",
                 title: "Live Action Thriller",
                 year: 2024,
                 metadata: metadata(genres: ["Thriller"], content_rating: "R")
               },
               skip_episode_refresh: true
             )
  end

  test "creating an in-bounds item succeeds" do
    assert {:ok, item} =
             Media.create_media_item(
               cartoon_only_scope(),
               %{
                 type: "movie",
                 title: "Animated Feature",
                 year: 2024,
                 metadata: metadata(genres: ["Animation"], content_rating: "G")
               },
               skip_episode_refresh: true
             )

    assert item.category == "cartoon_movie"
  end

  test "an unrestricted scope creates anything" do
    assert {:ok, _} =
             Media.create_media_item(
               Scope.unrestricted(),
               %{
                 type: "movie",
                 title: "Anything At All",
                 year: 2024,
                 metadata: metadata(genres: ["Thriller"], content_rating: "R")
               },
               skip_episode_refresh: true
             )
  end

  test "an age limit blocks creation of a title above it" do
    scope = Scope.for_user(restricted_user_fixture(%{max_content_age: 7}))

    assert {:error, :restricted} =
             Media.create_media_item(
               scope,
               %{
                 type: "movie",
                 title: "Too Old For This",
                 year: 2024,
                 metadata: metadata(genres: ["Animation"], content_rating: "R")
               },
               skip_episode_refresh: true
             )
  end

  test "a restricted account cannot move an item out of bounds by update" do
    scope = cartoon_only_scope()

    {:ok, item} =
      Media.create_media_item(
        scope,
        %{
          type: "movie",
          title: "Starts Animated",
          year: 2024,
          metadata: metadata(genres: ["Animation"], content_rating: "G")
        },
        skip_episode_refresh: true
      )

    assert {:error, :restricted} =
             Media.update_media_item(scope, item, %{
               metadata: metadata(genres: ["Thriller"], content_rating: "R")
             })
  end

  test "an update that does not touch metadata is judged by the stored metadata, not its absence" do
    scope = cartoon_only_scope()

    {:ok, item} =
      Media.create_media_item(
        scope,
        %{
          type: "movie",
          title: "Cartoon Original Title",
          year: 2024,
          metadata: metadata(genres: ["Animation"], content_rating: "G")
        },
        skip_episode_refresh: true
      )

    assert {:ok, updated} = Media.update_media_item(scope, item, %{title: "Cartoon Renamed"})
    assert updated.title == "Cartoon Renamed"
  end
end
