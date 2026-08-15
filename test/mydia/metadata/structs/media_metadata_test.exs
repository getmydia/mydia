defmodule Mydia.Metadata.Structs.MediaMetadataTest do
  use ExUnit.Case, async: true

  alias Mydia.Metadata.Structs.MediaMetadata

  describe "content_rating for movies" do
    test "picks the US certification when present" do
      body = %{
        "id" => 603,
        "title" => "The Matrix",
        "release_date" => "1999-03-30",
        "credits" => %{"cast" => [], "crew" => []},
        "release_dates" => %{
          "results" => [
            %{
              "iso_3166_1" => "FR",
              "release_dates" => [%{"certification" => "U"}]
            },
            %{
              "iso_3166_1" => "US",
              "release_dates" => [%{"certification" => ""}, %{"certification" => "R"}]
            }
          ]
        }
      }

      metadata = MediaMetadata.from_api_response(body, :movie, "603")

      assert metadata.content_rating == "R"
    end

    test "falls back to GB, then to the first non-blank certification" do
      body_gb = %{
        "id" => 1,
        "title" => "Import",
        "credits" => %{"cast" => [], "crew" => []},
        "release_dates" => %{
          "results" => [
            %{"iso_3166_1" => "GB", "release_dates" => [%{"certification" => "15"}]}
          ]
        }
      }

      assert MediaMetadata.from_api_response(body_gb, :movie, "1").content_rating == "15"

      body_other = %{
        "id" => 2,
        "title" => "Obscure",
        "credits" => %{"cast" => [], "crew" => []},
        "release_dates" => %{
          "results" => [
            %{"iso_3166_1" => "JP", "release_dates" => [%{"certification" => "PG12"}]}
          ]
        }
      }

      assert MediaMetadata.from_api_response(body_other, :movie, "2").content_rating == "PG12"
    end

    test "is nil when no country has a non-blank certification" do
      body = %{
        "id" => 3,
        "title" => "Uncertified",
        "credits" => %{"cast" => [], "crew" => []},
        "release_dates" => %{
          "results" => [
            %{"iso_3166_1" => "US", "release_dates" => [%{"certification" => ""}]}
          ]
        }
      }

      assert MediaMetadata.from_api_response(body, :movie, "3").content_rating == nil
    end

    test "is nil when release_dates is absent entirely" do
      body = %{
        "id" => 4,
        "title" => "No Data",
        "credits" => %{"cast" => [], "crew" => []}
      }

      assert MediaMetadata.from_api_response(body, :movie, "4").content_rating == nil
    end
  end

  describe "recommended_tmdb_ids" do
    test "extracts ids from the recommendations response, capped at 20" do
      results = for id <- 1..25, do: %{"id" => id, "title" => "Movie #{id}"}

      body = %{
        "id" => 603,
        "title" => "The Matrix",
        "credits" => %{"cast" => [], "crew" => []},
        "recommendations" => %{"results" => results}
      }

      metadata = MediaMetadata.from_api_response(body, :movie, "603")

      assert length(metadata.recommended_tmdb_ids) == 20
      assert metadata.recommended_tmdb_ids == Enum.to_list(1..20)
    end

    test "is an empty list when recommendations is absent" do
      body = %{
        "id" => 603,
        "title" => "The Matrix",
        "credits" => %{"cast" => [], "crew" => []}
      }

      assert MediaMetadata.from_api_response(body, :movie, "603").recommended_tmdb_ids == []
    end
  end

  describe "videos" do
    test "sorts the official trailer before an unofficial one, regardless of publish date" do
      body = %{
        "id" => 603,
        "title" => "The Matrix",
        "credits" => %{"cast" => [], "crew" => []},
        "videos" => %{
          "results" => [
            %{
              "site" => "YouTube",
              "type" => "Trailer",
              "key" => "unofficial",
              "official" => false,
              "published_at" => "2020-01-01T00:00:00.000Z"
            },
            %{
              "site" => "YouTube",
              "type" => "Trailer",
              "key" => "official",
              "official" => true,
              "published_at" => "2019-01-01T00:00:00.000Z"
            }
          ]
        }
      }

      metadata = MediaMetadata.from_api_response(body, :movie, "603")

      assert hd(metadata.videos).official == true
      assert hd(metadata.videos).key == "official"
    end
  end

  describe "content_rating for TV shows" do
    test "picks the US rating when present" do
      body = %{
        "id" => 1396,
        "name" => "Breaking Bad",
        "first_air_date" => "2008-01-20",
        "credits" => %{"cast" => [], "crew" => []},
        "content_ratings" => %{
          "results" => [
            %{"iso_3166_1" => "GB", "rating" => "18"},
            %{"iso_3166_1" => "US", "rating" => "TV-MA"}
          ]
        }
      }

      metadata = MediaMetadata.from_api_response(body, :tv_show, "1396")

      assert metadata.content_rating == "TV-MA"
    end

    test "is nil when content_ratings is absent entirely" do
      body = %{
        "id" => 1,
        "name" => "No Data",
        "credits" => %{"cast" => [], "crew" => []}
      }

      assert MediaMetadata.from_api_response(body, :tv_show, "1").content_rating == nil
    end
  end

  describe "external_ids" do
    test "parses the TMDB external_ids block for a TV show" do
      body = %{
        "id" => 1399,
        "name" => "Game of Thrones",
        "first_air_date" => "2011-04-17",
        "credits" => %{"cast" => [], "crew" => []},
        "external_ids" => %{"tvdb_id" => 121_361, "imdb_id" => "tt0944947"}
      }

      metadata = MediaMetadata.from_api_response(body, :tv_show, "1399")

      assert metadata.external_ids == %{tmdb: nil, tvdb: 121_361, imdb: "tt0944947"}
    end

    test "fills imdb_id from external_ids when TMDB sends no top-level one" do
      body = %{
        "id" => 1399,
        "name" => "Game of Thrones",
        "credits" => %{"cast" => [], "crew" => []},
        "external_ids" => %{"tvdb_id" => 121_361, "imdb_id" => "tt0944947"}
      }

      metadata = MediaMetadata.from_api_response(body, :tv_show, "1399")

      assert metadata.imdb_id == "tt0944947"
    end

    test "keeps the top-level imdb_id when both are present" do
      body = %{
        "id" => 603,
        "title" => "The Matrix",
        "imdb_id" => "tt0133093",
        "credits" => %{"cast" => [], "crew" => []},
        "external_ids" => %{"imdb_id" => "tt-should-lose"}
      }

      metadata = MediaMetadata.from_api_response(body, :movie, "603")

      assert metadata.imdb_id == "tt0133093"
    end

    test "leaves external_ids nil when the block was never requested" do
      body = %{
        "id" => 1399,
        "name" => "Game of Thrones",
        "credits" => %{"cast" => [], "crew" => []}
      }

      metadata = MediaMetadata.from_api_response(body, :tv_show, "1399")

      assert metadata.external_ids == nil
    end

    test "coerces a string tvdb_id and rejects an unparseable one" do
      base = %{"id" => 1399, "name" => "X", "credits" => %{"cast" => [], "crew" => []}}

      good =
        MediaMetadata.from_api_response(
          Map.put(base, "external_ids", %{"tvdb_id" => "121361"}),
          :tv_show,
          "1399"
        )

      bad =
        MediaMetadata.from_api_response(
          Map.put(base, "external_ids", %{"tvdb_id" => "not-a-number"}),
          :tv_show,
          "1399"
        )

      assert good.external_ids.tvdb == 121_361
      assert bad.external_ids.tvdb == nil
    end
  end
end
