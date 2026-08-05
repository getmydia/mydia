defmodule MydiaWeb.SchemaTest do
  use MydiaWeb.ConnCase

  import Ecto.Query

  alias Absinthe.Schema
  alias Mydia.AccountsFixtures
  alias Mydia.MediaFixtures

  describe "GraphQL Schema" do
    test "schema compiles and introspects successfully" do
      assert {:ok, introspection} = Schema.introspect(MydiaWeb.Schema)
      assert introspection.data["__schema"]
    end

    test "has Query type" do
      {:ok, introspection} = Schema.introspect(MydiaWeb.Schema)
      assert introspection.data["__schema"]["queryType"]
      assert introspection.data["__schema"]["queryType"]["name"] == "RootQueryType"
    end

    test "has Mutation type" do
      {:ok, introspection} = Schema.introspect(MydiaWeb.Schema)
      assert introspection.data["__schema"]["mutationType"]
      assert introspection.data["__schema"]["mutationType"]["name"] == "RootMutationType"
    end

    test "defines Movie type" do
      {:ok, introspection} = Schema.introspect(MydiaWeb.Schema)
      types = introspection.data["__schema"]["types"]

      movie_type = Enum.find(types, fn t -> t["name"] == "Movie" end)
      assert movie_type
      assert movie_type["kind"] == "OBJECT"

      field_names = Enum.map(movie_type["fields"], & &1["name"])
      assert "id" in field_names
      assert "title" in field_names
      assert "year" in field_names
      assert "overview" in field_names
      assert "artwork" in field_names
      assert "files" in field_names
      assert "progress" in field_names
    end

    test "defines TvShow type" do
      {:ok, introspection} = Schema.introspect(MydiaWeb.Schema)
      types = introspection.data["__schema"]["types"]

      tv_show_type = Enum.find(types, fn t -> t["name"] == "TvShow" end)
      assert tv_show_type
      assert tv_show_type["kind"] == "OBJECT"

      field_names = Enum.map(tv_show_type["fields"], & &1["name"])
      assert "id" in field_names
      assert "title" in field_names
      assert "seasons" in field_names
      assert "nextEpisode" in field_names
    end

    test "TvShow exposes metadataSource provenance" do
      {:ok, introspection} = Schema.introspect(MydiaWeb.Schema)
      types = introspection.data["__schema"]["types"]

      tv_show_type = Enum.find(types, fn t -> t["name"] == "TvShow" end)
      field_names = Enum.map(tv_show_type["fields"], & &1["name"])
      assert "metadataSource" in field_names
    end

    test "LibraryPath exposes tvMetadataSource" do
      {:ok, introspection} = Schema.introspect(MydiaWeb.Schema)
      types = introspection.data["__schema"]["types"]

      library_path_type = Enum.find(types, fn t -> t["name"] == "LibraryPath" end)
      assert library_path_type
      field_names = Enum.map(library_path_type["fields"], & &1["name"])
      assert "tvMetadataSource" in field_names
    end

    test "defines Episode type" do
      {:ok, introspection} = Schema.introspect(MydiaWeb.Schema)
      types = introspection.data["__schema"]["types"]

      episode_type = Enum.find(types, fn t -> t["name"] == "Episode" end)
      assert episode_type
      assert episode_type["kind"] == "OBJECT"

      field_names = Enum.map(episode_type["fields"], & &1["name"])
      assert "id" in field_names
      assert "seasonNumber" in field_names
      assert "episodeNumber" in field_names
      assert "title" in field_names
      assert "files" in field_names
      assert "progress" in field_names
      assert "show" in field_names
    end

    test "defines Season type" do
      {:ok, introspection} = Schema.introspect(MydiaWeb.Schema)
      types = introspection.data["__schema"]["types"]

      season_type = Enum.find(types, fn t -> t["name"] == "Season" end)
      assert season_type
      assert season_type["kind"] == "OBJECT"

      field_names = Enum.map(season_type["fields"], & &1["name"])
      assert "seasonNumber" in field_names
      assert "episodeCount" in field_names
      assert "episodes" in field_names
    end

    test "defines MovieConnection for pagination" do
      {:ok, introspection} = Schema.introspect(MydiaWeb.Schema)
      types = introspection.data["__schema"]["types"]

      connection_type = Enum.find(types, fn t -> t["name"] == "MovieConnection" end)
      assert connection_type
      assert connection_type["kind"] == "OBJECT"

      field_names = Enum.map(connection_type["fields"], & &1["name"])
      assert "edges" in field_names
      assert "pageInfo" in field_names
      assert "totalCount" in field_names
    end

    test "defines enum types" do
      {:ok, introspection} = Schema.introspect(MydiaWeb.Schema)
      types = introspection.data["__schema"]["types"]

      assert Enum.find(types, fn t -> t["name"] == "MediaType" end)
      assert Enum.find(types, fn t -> t["name"] == "SortField" end)
      assert Enum.find(types, fn t -> t["name"] == "SortDirection" end)
    end

    test "has browse query fields" do
      {:ok, introspection} = Schema.introspect(MydiaWeb.Schema)
      types = introspection.data["__schema"]["types"]

      query_type = Enum.find(types, fn t -> t["name"] == "RootQueryType" end)
      field_names = Enum.map(query_type["fields"], & &1["name"])

      assert "movie" in field_names
      assert "tvShow" in field_names
      assert "episode" in field_names
      assert "movies" in field_names
      assert "tvShows" in field_names
      assert "seasonEpisodes" in field_names
    end

    test "has discovery query fields" do
      {:ok, introspection} = Schema.introspect(MydiaWeb.Schema)
      types = introspection.data["__schema"]["types"]

      query_type = Enum.find(types, fn t -> t["name"] == "RootQueryType" end)
      field_names = Enum.map(query_type["fields"], & &1["name"])

      assert "continueWatching" in field_names
      assert "recentlyAdded" in field_names
      assert "upNext" in field_names
      assert "search" in field_names
    end

    test "has mutation fields" do
      {:ok, introspection} = Schema.introspect(MydiaWeb.Schema)
      types = introspection.data["__schema"]["types"]

      mutation_type = Enum.find(types, fn t -> t["name"] == "RootMutationType" end)
      field_names = Enum.map(mutation_type["fields"], & &1["name"])

      assert "updateMovieProgress" in field_names
      assert "updateEpisodeProgress" in field_names
      assert "markMovieWatched" in field_names
      assert "markMovieUnwatched" in field_names
      assert "markEpisodeWatched" in field_names
      assert "markEpisodeUnwatched" in field_names
      assert "markSeasonWatched" in field_names
    end

    test "defines Node interface with hierarchical fields" do
      {:ok, introspection} = Schema.introspect(MydiaWeb.Schema)
      types = introspection.data["__schema"]["types"]

      # Check for Node interface
      node_interface = Enum.find(types, fn t -> t["name"] == "Node" end)
      assert node_interface
      assert node_interface["kind"] == "INTERFACE"

      # Check interface fields
      field_names = Enum.map(node_interface["fields"], & &1["name"])
      assert "id" in field_names
      assert "parent" in field_names
      assert "children" in field_names
      assert "ancestors" in field_names
      assert "isPlayable" in field_names
    end

    test "Movie implements Node interface" do
      {:ok, introspection} = Schema.introspect(MydiaWeb.Schema)
      types = introspection.data["__schema"]["types"]

      movie_type = Enum.find(types, fn t -> t["name"] == "Movie" end)
      movie_interfaces = Enum.map(movie_type["interfaces"], & &1["name"])
      assert "Node" in movie_interfaces

      # Verify Movie has all interface fields
      field_names = Enum.map(movie_type["fields"], & &1["name"])
      assert "parent" in field_names
      assert "children" in field_names
      assert "ancestors" in field_names
      assert "isPlayable" in field_names
    end

    test "TvShow implements Node interface" do
      {:ok, introspection} = Schema.introspect(MydiaWeb.Schema)
      types = introspection.data["__schema"]["types"]

      tv_show_type = Enum.find(types, fn t -> t["name"] == "TvShow" end)
      tv_show_interfaces = Enum.map(tv_show_type["interfaces"], & &1["name"])
      assert "Node" in tv_show_interfaces
    end

    test "Episode implements Node interface" do
      {:ok, introspection} = Schema.introspect(MydiaWeb.Schema)
      types = introspection.data["__schema"]["types"]

      episode_type = Enum.find(types, fn t -> t["name"] == "Episode" end)
      episode_interfaces = Enum.map(episode_type["interfaces"], & &1["name"])
      assert "Node" in episode_interfaces
    end

    test "Season implements Node interface" do
      {:ok, introspection} = Schema.introspect(MydiaWeb.Schema)
      types = introspection.data["__schema"]["types"]

      season_type = Enum.find(types, fn t -> t["name"] == "Season" end)
      season_interfaces = Enum.map(season_type["interfaces"], & &1["name"])
      assert "Node" in season_interfaces

      # Verify Season now has an id field
      field_names = Enum.map(season_type["fields"], & &1["name"])
      assert "id" in field_names
    end

    test "LibraryPath implements Node interface" do
      {:ok, introspection} = Schema.introspect(MydiaWeb.Schema)
      types = introspection.data["__schema"]["types"]

      library_path_type = Enum.find(types, fn t -> t["name"] == "LibraryPath" end)
      library_path_interfaces = Enum.map(library_path_type["interfaces"], & &1["name"])
      assert "Node" in library_path_interfaces
    end

    test "has Subscription type" do
      {:ok, introspection} = Schema.introspect(MydiaWeb.Schema)
      assert introspection.data["__schema"]["subscriptionType"]
      assert introspection.data["__schema"]["subscriptionType"]["name"] == "RootSubscriptionType"
    end

    test "has device subscription fields" do
      {:ok, introspection} = Schema.introspect(MydiaWeb.Schema)
      types = introspection.data["__schema"]["types"]

      subscription_type = Enum.find(types, fn t -> t["name"] == "RootSubscriptionType" end)
      field_names = Enum.map(subscription_type["fields"], & &1["name"])

      assert "deviceStatusChanged" in field_names
      assert "progressUpdated" in field_names
    end

    test "defines DeviceStatusEvent type" do
      {:ok, introspection} = Schema.introspect(MydiaWeb.Schema)
      types = introspection.data["__schema"]["types"]

      device_status_event_type = Enum.find(types, fn t -> t["name"] == "DeviceStatusEvent" end)
      assert device_status_event_type
      assert device_status_event_type["kind"] == "OBJECT"

      field_names = Enum.map(device_status_event_type["fields"], & &1["name"])
      assert "device" in field_names
      assert "event" in field_names
    end

    test "defines Device type" do
      {:ok, introspection} = Schema.introspect(MydiaWeb.Schema)
      types = introspection.data["__schema"]["types"]

      device_type = Enum.find(types, fn t -> t["name"] == "Device" end)
      assert device_type
      assert device_type["kind"] == "OBJECT"

      field_names = Enum.map(device_type["fields"], & &1["name"])
      assert "id" in field_names
      assert "deviceName" in field_names
      assert "platform" in field_names
      assert "lastSeenAt" in field_names
      assert "revokedAt" in field_names
      assert "insertedAt" in field_names
    end

    test "defines DeviceEventType enum" do
      {:ok, introspection} = Schema.introspect(MydiaWeb.Schema)
      types = introspection.data["__schema"]["types"]

      device_event_type_enum = Enum.find(types, fn t -> t["name"] == "DeviceEventType" end)
      assert device_event_type_enum
      assert device_event_type_enum["kind"] == "ENUM"

      enum_values = Enum.map(device_event_type_enum["enumValues"], & &1["name"])
      assert "CONNECTED" in enum_values
      assert "DISCONNECTED" in enum_values
      assert "REVOKED" in enum_values
      assert "DELETED" in enum_values
    end
  end

  describe "recentlyAdded with content timestamps" do
    setup do
      %{user: AccountsFixtures.user_fixture()}
    end

    test "surfaces a long-owned show after a new episode arrives", %{user: user} do
      show = MediaFixtures.media_item_fixture(%{type: "tv_show", title: "The Bear"})

      episode =
        MediaFixtures.episode_fixture(%{
          media_item_id: show.id,
          season_number: 4,
          episode_number: 2
        })

      file = MediaFixtures.media_file_fixture(%{episode_id: episode.id})
      MediaFixtures.backdate_media_file(file, DateTime.add(DateTime.utc_now(), -2, :day))

      # The show record itself is ancient; only its content is new.
      Mydia.Repo.update_all(
        from(m in Mydia.Media.MediaItem, where: m.id == ^show.id),
        set: [inserted_at: ~U[2024-01-01 00:00:00Z]]
      )

      query = """
      query {
        recentlyAdded(first: 10) {
          id
          title
          addedAt
          newEpisodeCount
          latestSeasonNumber
          latestEpisodeNumber
        }
      }
      """

      assert {:ok, %{data: %{"recentlyAdded" => [item]}}} = run_query(query, %{}, user)

      assert item["id"] == show.id
      assert item["newEpisodeCount"] == 1
      assert item["latestSeasonNumber"] == 4
      assert item["latestEpisodeNumber"] == 2
      refute String.starts_with?(item["addedAt"], "2024")
    end

    test "a movie reports nil episode context", %{user: user} do
      movie = MediaFixtures.media_item_fixture(%{type: "movie"})
      file = MediaFixtures.media_file_fixture(%{media_item_id: movie.id})
      MediaFixtures.backdate_media_file(file, DateTime.add(DateTime.utc_now(), -2, :day))

      query = """
      query {
        recentlyAdded(first: 10) {
          id
          newEpisodeCount
          latestSeasonNumber
        }
      }
      """

      assert {:ok, %{data: %{"recentlyAdded" => [item]}}} = run_query(query, %{}, user)

      assert item["id"] == movie.id
      assert item["newEpisodeCount"] == nil
      assert item["latestSeasonNumber"] == nil
    end

    test "favorites reports the corrected timestamp with nil context", %{user: user} do
      movie = MediaFixtures.media_item_fixture(%{type: "movie"})
      file = MediaFixtures.media_file_fixture(%{media_item_id: movie.id})
      MediaFixtures.backdate_media_file(file, ~U[2026-08-03 12:00:00Z])

      favorite_item(user, movie)

      query = """
      query {
        favorites(first: 10) {
          id
          addedAt
          newEpisodeCount
        }
      }
      """

      assert {:ok, %{data: %{"favorites" => [item]}}} = run_query(query, %{}, user)

      assert item["id"] == movie.id
      assert item["addedAt"] =~ "2026-08-03"
      assert item["newEpisodeCount"] == nil
    end

    test "rejects the new fields with a recognizable message when absent" do
      # Pins the string that the player's downgrade detector matches on. If
      # Absinthe ever rephrases this, the player guard must be updated in the
      # same change.
      query = "query { recentlyAdded(first: 1) { id noSuchField } }"

      {:ok, %{errors: [error | _]}} = Absinthe.run(query, MydiaWeb.Schema)

      assert error.message =~ "Cannot query field"
    end
  end

  defp run_query(query, variables, user) do
    Absinthe.run(query, MydiaWeb.Schema, variables: variables, context: %{current_user: user})
  end

  defp favorite_item(user, media_item) do
    {:ok, _} = Mydia.Media.toggle_favorite(user.id, media_item.id)
  end
end
