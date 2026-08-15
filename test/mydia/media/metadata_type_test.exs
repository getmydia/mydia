defmodule Mydia.Media.MetadataTypeTest do
  use Mydia.DataCase, async: true

  alias Mydia.Media
  alias Mydia.Media.MetadataType
  alias Mydia.Metadata.Structs.{MediaMetadata, CastMember, CrewMember, SeasonInfo}

  describe "type safety and round-trip conversion" do
    test "loading media item from database returns MediaMetadata struct, not plain map" do
      # Create a media item with full metadata
      {:ok, media_item} =
        Media.create_media_item(%{
          type: "movie",
          title: "The Matrix",
          year: 1999,
          tmdb_id: 603,
          metadata: %{
            "id" => 603,
            "provider_id" => "603",
            "provider" => "metadata_relay",
            "media_type" => "movie",
            "title" => "The Matrix",
            "original_title" => "The Matrix",
            "overview" => "Set in the 22nd century...",
            "year" => 1999,
            "runtime" => 136,
            "genres" => ["Action", "Science Fiction"],
            "cast" => [
              %{"name" => "Keanu Reeves", "character" => "Neo", "order" => 0}
            ],
            "crew" => [
              %{
                "name" => "Lana Wachowski",
                "job" => "Director",
                "department" => "Directing"
              }
            ],
            "alternative_titles" => ["The Matrix Reloaded"]
          }
        })

      # Reload from database to verify round-trip
      reloaded = Repo.get!(Mydia.Media.MediaItem, media_item.id)

      # Verify metadata is a MediaMetadata struct
      assert %MediaMetadata{} = reloaded.metadata
      assert is_struct(reloaded.metadata, MediaMetadata)

      # Verify we get compile-time safety - accessing fields works
      assert reloaded.metadata.title == "The Matrix"
      assert reloaded.metadata.overview == "Set in the 22nd century..."
      assert reloaded.metadata.year == 1999
      assert reloaded.metadata.runtime == 136

      # Verify nested structs are properly converted
      assert is_list(reloaded.metadata.cast)
      assert [%CastMember{} | _] = reloaded.metadata.cast
      assert hd(reloaded.metadata.cast).name == "Keanu Reeves"
      assert hd(reloaded.metadata.cast).character == "Neo"

      assert is_list(reloaded.metadata.crew)
      assert [%CrewMember{} | _] = reloaded.metadata.crew
      assert hd(reloaded.metadata.crew).name == "Lana Wachowski"
      assert hd(reloaded.metadata.crew).job == "Director"

      # Verify alternative titles are properly handled
      assert is_list(reloaded.metadata.alternative_titles)
      assert "The Matrix Reloaded" in reloaded.metadata.alternative_titles
    end

    test "handles TV show metadata with seasons" do
      {:ok, media_item} =
        Media.create_media_item(
          %{
            type: "tv_show",
            title: "Breaking Bad",
            year: 2008,
            tmdb_id: 1396,
            metadata: %{
              "id" => 1396,
              "provider_id" => "1396",
              "provider" => "metadata_relay",
              "media_type" => "tv_show",
              "title" => "Breaking Bad",
              "number_of_seasons" => 5,
              "number_of_episodes" => 62,
              "seasons" => [
                %{"season_number" => 1, "name" => "Season 1", "episode_count" => 7}
              ]
            }
          },
          skip_episode_refresh: true
        )

      reloaded = Repo.get!(Mydia.Media.MediaItem, media_item.id)

      assert %MediaMetadata{} = reloaded.metadata
      assert reloaded.metadata.media_type == :tv_show
      assert reloaded.metadata.number_of_seasons == 5
      assert reloaded.metadata.number_of_episodes == 62

      # Verify seasons are properly converted to SeasonInfo structs
      assert is_list(reloaded.metadata.seasons)
      assert [%SeasonInfo{} | _] = reloaded.metadata.seasons
      assert hd(reloaded.metadata.seasons).season_number == 1
      assert hd(reloaded.metadata.seasons).name == "Season 1"
      assert hd(reloaded.metadata.seasons).episode_count == 7
    end

    test "handles nil metadata gracefully" do
      {:ok, media_item} =
        Media.create_media_item(%{
          type: "movie",
          title: "Test Movie",
          year: 2024
        })

      reloaded = Repo.get!(Mydia.Media.MediaItem, media_item.id)
      assert is_nil(reloaded.metadata)
    end

    test "handles partial metadata with missing optional fields" do
      {:ok, media_item} =
        Media.create_media_item(%{
          type: "movie",
          title: "Minimal Movie",
          year: 2024,
          metadata: %{
            "id" => 999,
            "provider_id" => "999",
            "provider" => "metadata_relay",
            "media_type" => "movie",
            "title" => "Minimal Movie"
          }
        })

      reloaded = Repo.get!(Mydia.Media.MediaItem, media_item.id)

      assert %MediaMetadata{} = reloaded.metadata
      assert reloaded.metadata.title == "Minimal Movie"
      assert is_nil(reloaded.metadata.overview)
      assert is_nil(reloaded.metadata.runtime)
      assert is_nil(reloaded.metadata.cast)
      assert is_nil(reloaded.metadata.crew)
    end

    test "collection pointer survives a database round trip" do
      {:ok, media_item} =
        Media.create_media_item(%{
          type: "movie",
          title: "Harry Potter and the Philosopher's Stone",
          year: 2001,
          tmdb_id: 671,
          metadata: %{
            "provider_id" => "671",
            "provider" => "metadata_relay",
            "media_type" => "movie",
            "title" => "Harry Potter and the Philosopher's Stone",
            "collection_id" => 1241,
            "collection_name" => "Harry Potter Collection"
          }
        })

      reloaded = Media.get_media_item!(media_item.id)

      assert %MediaMetadata{} = reloaded.metadata
      assert reloaded.metadata.collection_id == 1241
      assert reloaded.metadata.collection_name == "Harry Potter Collection"
    end

    test "collection pointer is nil when the movie has no franchise" do
      {:ok, media_item} =
        Media.create_media_item(%{
          type: "movie",
          title: "Standalone Movie",
          year: 1999,
          tmdb_id: 603,
          metadata: %{
            "provider_id" => "603",
            "provider" => "metadata_relay",
            "media_type" => "movie",
            "title" => "Standalone Movie"
          }
        })

      reloaded = Media.get_media_item!(media_item.id)

      assert reloaded.metadata.collection_id == nil
      assert reloaded.metadata.collection_name == nil
    end

    test "content rating survives a database round trip" do
      {:ok, media_item} =
        Media.create_media_item(%{
          type: "movie",
          title: "The Matrix",
          year: 1999,
          tmdb_id: 603,
          metadata: %{
            "provider_id" => "603",
            "provider" => "metadata_relay",
            "media_type" => "movie",
            "title" => "The Matrix",
            "content_rating" => "R"
          }
        })

      reloaded = Media.get_media_item!(media_item.id)

      assert reloaded.metadata.content_rating == "R"
    end

    test "recommended tmdb ids survive a database round trip" do
      {:ok, media_item} =
        Media.create_media_item(%{
          type: "movie",
          title: "The Matrix",
          year: 1999,
          tmdb_id: 603,
          metadata: %{
            "provider_id" => "603",
            "provider" => "metadata_relay",
            "media_type" => "movie",
            "title" => "The Matrix",
            "recommended_tmdb_ids" => [604, 605, 606]
          }
        })

      reloaded = Media.get_media_item!(media_item.id)

      assert reloaded.metadata.recommended_tmdb_ids == [604, 605, 606]
    end

    test "external_ids survive a database round trip" do
      {:ok, media_item} =
        Media.create_media_item(%{
          type: "tv_show",
          title: "Game of Thrones",
          year: 2011,
          tvdb_id: 121_361,
          metadata: %{
            "provider_id" => "121361",
            "provider" => "tvdb",
            "media_type" => "tv_show",
            "title" => "Game of Thrones",
            "external_ids" => %{"tmdb" => 1399, "tvdb" => nil, "imdb" => "tt0944947"}
          }
        })

      reloaded = Media.get_media_item!(media_item.id)

      assert reloaded.metadata.external_ids == %{tmdb: 1399, tvdb: nil, imdb: "tt0944947"}
    end

    test "external_ids stays nil across a database round trip when never asked" do
      {:ok, media_item} =
        Media.create_media_item(%{
          type: "movie",
          title: "Standalone Movie",
          year: 1999,
          tmdb_id: 603,
          metadata: %{
            "provider_id" => "603",
            "provider" => "metadata_relay",
            "media_type" => "movie",
            "title" => "Standalone Movie"
          }
        })

      reloaded = Media.get_media_item!(media_item.id)

      assert reloaded.metadata.external_ids == nil
    end
  end

  describe "Ecto.Type callbacks" do
    test "type/0 returns :string for text column compatibility" do
      assert MetadataType.type() == :string
    end

    test "cast/1 accepts MediaMetadata struct" do
      metadata = %MediaMetadata{
        provider_id: "603",
        provider: :metadata_relay,
        media_type: :movie,
        title: "The Matrix"
      }

      assert {:ok, ^metadata} = MetadataType.cast(metadata)
    end

    test "cast/1 converts plain map to MediaMetadata" do
      map = %{
        "provider_id" => "603",
        "provider" => "metadata_relay",
        "media_type" => "movie",
        "title" => "The Matrix"
      }

      assert {:ok, %MediaMetadata{} = metadata} = MetadataType.cast(map)
      assert metadata.provider_id == "603"
      assert metadata.provider == :metadata_relay
      assert metadata.media_type == :movie
      assert metadata.title == "The Matrix"
    end

    test "cast/1 handles nil" do
      assert {:ok, nil} = MetadataType.cast(nil)
    end

    test "load/1 converts JSON string to MediaMetadata struct" do
      json =
        Jason.encode!(%{
          "provider_id" => "603",
          "provider" => "metadata_relay",
          "media_type" => "movie",
          "title" => "The Matrix",
          "cast" => [
            %{"name" => "Keanu Reeves", "character" => "Neo", "order" => 0}
          ]
        })

      assert {:ok, %MediaMetadata{} = metadata} = MetadataType.load(json)
      assert metadata.title == "The Matrix"
      assert [%CastMember{} | _] = metadata.cast
      assert hd(metadata.cast).name == "Keanu Reeves"
    end

    test "load/1 also handles plain maps for adapter compatibility" do
      db_map = %{
        provider_id: "603",
        provider: :metadata_relay,
        media_type: :movie,
        title: "The Matrix"
      }

      assert {:ok, %MediaMetadata{} = metadata} = MetadataType.load(db_map)
      assert metadata.title == "The Matrix"
    end

    test "dump/1 converts MediaMetadata struct to JSON string" do
      metadata = %MediaMetadata{
        provider_id: "603",
        provider: :metadata_relay,
        media_type: :movie,
        title: "The Matrix",
        cast: [
          %CastMember{name: "Keanu Reeves", character: "Neo", order: 0}
        ],
        crew: [
          %CrewMember{name: "Lana Wachowski", job: "Director", department: "Directing"}
        ]
      }

      assert {:ok, json} = MetadataType.dump(metadata)
      assert is_binary(json)

      # Verify the JSON can be decoded back
      {:ok, map} = Jason.decode(json)
      assert is_map(map)
      assert map["title"] == "The Matrix"
      assert map["provider_id"] == "603"

      # Verify nested structs are converted to maps in JSON
      assert is_list(map["cast"])
      assert [cast_map | _] = map["cast"]
      assert cast_map["name"] == "Keanu Reeves"

      assert is_list(map["crew"])
      assert [crew_map | _] = map["crew"]
      assert crew_map["name"] == "Lana Wachowski"
    end
  end

  describe "compile-time type safety" do
    test "accessing fields on MediaMetadata struct doesn't silently return nil for typos" do
      metadata = %MediaMetadata{
        provider_id: "603",
        provider: :metadata_relay,
        media_type: :movie,
        title: "The Matrix"
      }

      # This should work
      assert metadata.title == "The Matrix"

      # This would raise a KeyError at compile time if we tried:
      # metadata.titl  # <- This typo would be caught!

      # Contrast with plain map which silently returns nil:
      plain_map = %{"title" => "The Matrix"}
      # <- Typo returns nil silently
      assert plain_map["titl"] == nil
    end
  end
end
