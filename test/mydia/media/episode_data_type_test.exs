defmodule Mydia.Media.EpisodeDataTypeTest do
  use Mydia.DataCase, async: true

  alias Mydia.Accounts.Scope
  alias Mydia.Media
  alias Mydia.Media.EpisodeDataType
  alias Mydia.Metadata.Structs.EpisodeData

  describe "type safety and round-trip conversion" do
    test "loading episode from database returns EpisodeData struct, not plain map" do
      # Create a media item first
      {:ok, media_item} =
        Media.create_media_item(
          Scope.unrestricted(),
          %{
            type: "tv_show",
            title: "Bluey",
            year: 2018,
            tmdb_id: 12345
          },
          skip_episode_refresh: true
        )

      # Create an episode with full metadata
      {:ok, episode} =
        Repo.insert(%Mydia.Media.Episode{
          media_item_id: media_item.id,
          season_number: 1,
          episode_number: 1,
          title: "The Magic Xylophone",
          metadata: %EpisodeData{
            season_number: 1,
            episode_number: 1,
            name: "The Magic Xylophone",
            overview:
              "As Bluey and Bingo squabble over their magic xylophone (that has the power to freeze Dad in space and time) Dad seizes control and freezes Bluey, leaving Bingo as her only hope.",
            air_date: ~D[2018-10-01],
            runtime: 7,
            still_path: "/4vrYTRSUjQ6i9BuyBwAyFHBWfO6.jpg",
            vote_average: 5.3,
            vote_count: 7
          }
        })

      # Reload from database to verify round-trip
      reloaded = Repo.get!(Mydia.Media.Episode, episode.id)

      # Verify metadata is an EpisodeData struct
      assert %EpisodeData{} = reloaded.metadata
      assert is_struct(reloaded.metadata, EpisodeData)

      # Verify we get compile-time safety - accessing fields works
      assert reloaded.metadata.season_number == 1
      assert reloaded.metadata.episode_number == 1
      assert reloaded.metadata.name == "The Magic Xylophone"
      assert reloaded.metadata.runtime == 7
      assert reloaded.metadata.vote_average == 5.3
      assert reloaded.metadata.vote_count == 7
      assert reloaded.metadata.still_path == "/4vrYTRSUjQ6i9BuyBwAyFHBWfO6.jpg"

      # Verify Date field is properly handled
      assert reloaded.metadata.air_date == ~D[2018-10-01]
      assert %Date{} = reloaded.metadata.air_date
    end

    test "handles nil metadata gracefully" do
      {:ok, media_item} =
        Media.create_media_item(
          Scope.unrestricted(),
          %{
            type: "tv_show",
            title: "Test Show",
            year: 2024
          },
          skip_episode_refresh: true
        )

      {:ok, episode} =
        Repo.insert(%Mydia.Media.Episode{
          media_item_id: media_item.id,
          season_number: 1,
          episode_number: 1,
          title: "Test Episode",
          metadata: nil
        })

      reloaded = Repo.get!(Mydia.Media.Episode, episode.id)
      assert is_nil(reloaded.metadata)
    end

    test "handles partial metadata with missing optional fields" do
      {:ok, media_item} =
        Media.create_media_item(
          Scope.unrestricted(),
          %{
            type: "tv_show",
            title: "Test Show",
            year: 2024
          },
          skip_episode_refresh: true
        )

      {:ok, episode} =
        Repo.insert(%Mydia.Media.Episode{
          media_item_id: media_item.id,
          season_number: 2,
          episode_number: 5,
          title: "Minimal Episode",
          metadata: %EpisodeData{
            season_number: 2,
            episode_number: 5,
            name: "Minimal Episode"
          }
        })

      reloaded = Repo.get!(Mydia.Media.Episode, episode.id)

      assert %EpisodeData{} = reloaded.metadata
      assert reloaded.metadata.name == "Minimal Episode"
      assert reloaded.metadata.season_number == 2
      assert reloaded.metadata.episode_number == 5
      assert is_nil(reloaded.metadata.overview)
      assert is_nil(reloaded.metadata.runtime)
      assert is_nil(reloaded.metadata.air_date)
      assert is_nil(reloaded.metadata.vote_average)
    end
  end

  describe "Ecto.Type callbacks" do
    test "type/0 returns :string for text column compatibility" do
      assert EpisodeDataType.type() == :string
    end

    test "cast/1 accepts EpisodeData struct" do
      episode_data = %EpisodeData{
        season_number: 1,
        episode_number: 1,
        name: "Test Episode"
      }

      assert {:ok, ^episode_data} = EpisodeDataType.cast(episode_data)
    end

    test "cast/1 converts plain map to EpisodeData" do
      map = %{
        "season_number" => 1,
        "episode_number" => 1,
        "name" => "Test Episode",
        "overview" => "Test overview",
        "air_date" => "2024-01-15",
        "runtime" => 30
      }

      assert {:ok, %EpisodeData{} = episode_data} = EpisodeDataType.cast(map)
      assert episode_data.season_number == 1
      assert episode_data.episode_number == 1
      assert episode_data.name == "Test Episode"
      assert episode_data.overview == "Test overview"
      assert episode_data.runtime == 30
      assert episode_data.air_date == ~D[2024-01-15]
    end

    test "cast/1 handles nil" do
      assert {:ok, nil} = EpisodeDataType.cast(nil)
    end

    test "load/1 converts JSON string to EpisodeData struct" do
      json =
        Jason.encode!(%{
          "season_number" => 1,
          "episode_number" => 2,
          "name" => "Database Episode",
          "overview" => "Loaded from DB",
          "air_date" => "2024-02-01",
          "runtime" => 45,
          "still_path" => "/test.jpg",
          "vote_average" => 8.5,
          "vote_count" => 100
        })

      assert {:ok, %EpisodeData{} = episode_data} = EpisodeDataType.load(json)
      assert episode_data.season_number == 1
      assert episode_data.episode_number == 2
      assert episode_data.name == "Database Episode"
      assert episode_data.air_date == ~D[2024-02-01]
      assert episode_data.vote_average == 8.5
    end

    test "load/1 also handles plain maps for adapter compatibility" do
      db_map = %{
        season_number: 1,
        episode_number: 2,
        name: "Database Episode"
      }

      assert {:ok, %EpisodeData{} = episode_data} = EpisodeDataType.load(db_map)
      assert episode_data.name == "Database Episode"
    end

    test "dump/1 converts EpisodeData struct to JSON string" do
      episode_data = %EpisodeData{
        season_number: 3,
        episode_number: 7,
        name: "Dump Test",
        overview: "Testing dump",
        air_date: ~D[2024-03-15],
        runtime: 60,
        still_path: "/dump.jpg",
        vote_average: 9.0,
        vote_count: 200
      }

      assert {:ok, json} = EpisodeDataType.dump(episode_data)
      assert is_binary(json)

      # Verify the JSON can be decoded back
      {:ok, map} = Jason.decode(json)
      assert is_map(map)
      assert map["season_number"] == 3
      assert map["episode_number"] == 7
      assert map["name"] == "Dump Test"
      # Date should be converted to ISO8601 string for DB storage
      assert map["air_date"] == "2024-03-15"
      assert map["runtime"] == 60
      assert map["vote_average"] == 9.0
    end

    test "dump/1 handles nil air_date" do
      episode_data = %EpisodeData{
        season_number: 1,
        episode_number: 1,
        name: "No Air Date",
        air_date: nil
      }

      assert {:ok, json} = EpisodeDataType.dump(episode_data)
      assert is_binary(json)
      {:ok, map} = Jason.decode(json)
      assert is_nil(map["air_date"])
    end
  end

  describe "compile-time type safety" do
    test "accessing fields on EpisodeData struct doesn't silently return nil for typos" do
      episode_data = %EpisodeData{
        season_number: 1,
        episode_number: 1,
        name: "Type Safety Test"
      }

      # This should work
      assert episode_data.name == "Type Safety Test"

      # This would raise a KeyError at compile time if we tried:
      # episode_data.nam  # <- This typo would be caught!

      # Contrast with plain map which silently returns nil:
      plain_map = %{"name" => "Type Safety Test"}
      # Typo returns nil silently
      assert plain_map["nam"] == nil
    end
  end
end
