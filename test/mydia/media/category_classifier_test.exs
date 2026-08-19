defmodule Mydia.Media.CategoryClassifierTest do
  use ExUnit.Case, async: true

  alias Mydia.Media.{CategoryClassifier, MediaItem}
  alias Mydia.Metadata.Structs.MediaMetadata

  doctest Mydia.Media.CategoryClassifier

  # Helper to build a MediaItem with metadata
  defp build_media_item(type, metadata_attrs) do
    metadata = build_metadata(metadata_attrs)
    %MediaItem{type: type, metadata: metadata, title: "Test"}
  end

  # Helper to build MediaMetadata struct
  defp build_metadata(attrs) do
    %MediaMetadata{
      provider_id: "123",
      provider: :metadata_relay,
      media_type: attrs[:media_type] || :movie,
      genres: attrs[:genres] || [],
      origin_country: attrs[:origin_country] || [],
      original_language: attrs[:original_language]
    }
  end

  describe "classify/1 for movies" do
    test "classifies regular live-action movie" do
      item = build_media_item("movie", %{genres: ["Action", "Drama"]})
      assert CategoryClassifier.classify(item) == :movie
    end

    test "classifies anime movie with origin_country JP" do
      item =
        build_media_item("movie", %{
          genres: ["Animation", "Action"],
          origin_country: ["JP"]
        })

      assert CategoryClassifier.classify(item) == :anime_movie
    end

    test "classifies anime movie with original_language ja" do
      item =
        build_media_item("movie", %{
          genres: ["Animation"],
          original_language: "ja"
        })

      assert CategoryClassifier.classify(item) == :anime_movie
    end

    test "classifies anime movie with Anime genre" do
      item = build_media_item("movie", %{genres: ["Anime", "Action"]})
      assert CategoryClassifier.classify(item) == :anime_movie
    end

    test "classifies cartoon movie (western animation)" do
      item =
        build_media_item("movie", %{
          genres: ["Animation", "Family"],
          origin_country: ["US"]
        })

      assert CategoryClassifier.classify(item) == :cartoon_movie
    end

    test "classifies cartoon movie when Animation genre present but not Japanese" do
      item =
        build_media_item("movie", %{
          genres: ["Animation"],
          origin_country: ["FR"],
          original_language: "fr"
        })

      assert CategoryClassifier.classify(item) == :cartoon_movie
    end

    test "classifies movie with nil metadata as regular movie" do
      item = %MediaItem{type: "movie", metadata: nil, title: "Test"}
      assert CategoryClassifier.classify(item) == :movie
    end
  end

  describe "classify/1 for TV shows" do
    test "classifies regular live-action TV show" do
      item = build_media_item("tv_show", %{genres: ["Drama", "Thriller"]})
      assert CategoryClassifier.classify(item) == :tv_show
    end

    test "classifies anime series with origin_country JP" do
      item =
        build_media_item("tv_show", %{
          genres: ["Animation"],
          origin_country: ["JP"]
        })

      assert CategoryClassifier.classify(item) == :anime_series
    end

    test "classifies anime series with original_language ja" do
      item =
        build_media_item("tv_show", %{
          genres: ["Animation", "Action"],
          original_language: "ja"
        })

      assert CategoryClassifier.classify(item) == :anime_series
    end

    test "classifies anime series with explicit Anime genre from TVDB" do
      item = build_media_item("tv_show", %{genres: ["Anime", "Sci-Fi"]})
      assert CategoryClassifier.classify(item) == :anime_series
    end

    test "classifies cartoon series (western animation)" do
      item =
        build_media_item("tv_show", %{
          genres: ["Animation", "Comedy"],
          origin_country: ["US"]
        })

      assert CategoryClassifier.classify(item) == :cartoon_series
    end

    test "classifies TV show with nil metadata as regular TV show" do
      item = %MediaItem{type: "tv_show", metadata: nil, title: "Test"}
      assert CategoryClassifier.classify(item) == :tv_show
    end
  end

  describe "classify_from_metadata/2" do
    test "classifies movie metadata" do
      metadata = build_metadata(%{genres: ["Animation"], origin_country: ["JP"]})
      assert CategoryClassifier.classify_from_metadata(:movie, metadata) == :anime_movie
    end

    test "classifies TV show metadata" do
      metadata = build_metadata(%{genres: ["Animation"], origin_country: ["US"]})
      assert CategoryClassifier.classify_from_metadata(:tv_show, metadata) == :cartoon_series
    end

    test "handles nil metadata" do
      assert CategoryClassifier.classify_from_metadata(:movie, nil) == :movie
      assert CategoryClassifier.classify_from_metadata(:tv_show, nil) == :tv_show
    end
  end

  describe "animated?/1" do
    test "returns true when Animation genre is present" do
      metadata = build_metadata(%{genres: ["Animation", "Comedy"]})
      assert CategoryClassifier.animated?(metadata) == true
    end

    test "returns true when Anime genre is present" do
      metadata = build_metadata(%{genres: ["Anime", "Action"]})
      assert CategoryClassifier.animated?(metadata) == true
    end

    test "returns false when no animation genres present" do
      metadata = build_metadata(%{genres: ["Drama", "Thriller"]})
      assert CategoryClassifier.animated?(metadata) == false
    end

    test "returns false for nil metadata" do
      assert CategoryClassifier.animated?(nil) == false
    end

    test "returns false for empty genres" do
      metadata = build_metadata(%{genres: []})
      assert CategoryClassifier.animated?(metadata) == false
    end

    test "works with plain maps" do
      assert CategoryClassifier.animated?(%{genres: ["Animation"]}) == true
      assert CategoryClassifier.animated?(%{genres: ["Drama"]}) == false
    end
  end

  describe "japanese_origin?/1" do
    test "returns true when origin_country includes JP" do
      metadata = build_metadata(%{origin_country: ["JP"]})
      assert CategoryClassifier.japanese_origin?(metadata) == true
    end

    test "returns true when origin_country includes JP among others" do
      metadata = build_metadata(%{origin_country: ["US", "JP"]})
      assert CategoryClassifier.japanese_origin?(metadata) == true
    end

    test "returns true when original_language is ja" do
      metadata = build_metadata(%{original_language: "ja"})
      assert CategoryClassifier.japanese_origin?(metadata) == true
    end

    test "returns true when Anime genre is present" do
      metadata = build_metadata(%{genres: ["Anime"]})
      assert CategoryClassifier.japanese_origin?(metadata) == true
    end

    test "returns false for non-Japanese content" do
      metadata = build_metadata(%{origin_country: ["US"], original_language: "en"})
      assert CategoryClassifier.japanese_origin?(metadata) == false
    end

    test "returns false for nil metadata" do
      assert CategoryClassifier.japanese_origin?(nil) == false
    end

    test "works with plain maps" do
      assert CategoryClassifier.japanese_origin?(%{origin_country: ["JP"]}) == true
      assert CategoryClassifier.japanese_origin?(%{original_language: "ja"}) == true
      assert CategoryClassifier.japanese_origin?(%{genres: ["Anime"]}) == true
      assert CategoryClassifier.japanese_origin?(%{origin_country: ["US"]}) == false
    end
  end

  describe "has_anime_genre?/1" do
    test "returns true when Anime genre is present" do
      metadata = build_metadata(%{genres: ["Anime", "Action"]})
      assert CategoryClassifier.has_anime_genre?(metadata) == true
    end

    test "returns false when only Animation genre is present" do
      metadata = build_metadata(%{genres: ["Animation", "Action"]})
      assert CategoryClassifier.has_anime_genre?(metadata) == false
    end

    test "returns false for nil metadata" do
      assert CategoryClassifier.has_anime_genre?(nil) == false
    end

    test "works with plain maps" do
      assert CategoryClassifier.has_anime_genre?(%{genres: ["Anime"]}) == true
      assert CategoryClassifier.has_anime_genre?(%{genres: ["Animation"]}) == false
    end
  end

  describe "edge cases" do
    test "handles media item with unknown type" do
      item = %MediaItem{type: "unknown", metadata: nil, title: "Test"}
      assert CategoryClassifier.classify(item) == :movie
    end

    test "prioritizes anime over cartoon when Japanese signals present" do
      # Animation + Japanese origin = anime, not cartoon
      item =
        build_media_item("movie", %{
          genres: ["Animation"],
          origin_country: ["JP"],
          original_language: "ja"
        })

      assert CategoryClassifier.classify(item) == :anime_movie
    end

    test "handles mixed origin countries with JP" do
      # Co-productions with Japan should still be classified as anime
      item =
        build_media_item("movie", %{
          genres: ["Animation"],
          origin_country: ["JP", "US", "CN"]
        })

      assert CategoryClassifier.classify(item) == :anime_movie
    end

    test "case sensitivity - genres must match exactly" do
      # "animation" lowercase should not match "Animation"
      metadata = build_metadata(%{genres: ["animation"]})
      assert CategoryClassifier.animated?(metadata) == false
    end
  end

  describe "real-world examples" do
    test "classifies Spirited Away (anime movie)" do
      item =
        build_media_item("movie", %{
          genres: ["Animation", "Family", "Fantasy"],
          origin_country: ["JP"],
          original_language: "ja"
        })

      assert CategoryClassifier.classify(item) == :anime_movie
    end

    test "classifies Toy Story (cartoon movie)" do
      item =
        build_media_item("movie", %{
          genres: ["Animation", "Adventure", "Comedy", "Family"],
          origin_country: ["US"],
          original_language: "en"
        })

      assert CategoryClassifier.classify(item) == :cartoon_movie
    end

    test "classifies The Shawshank Redemption (regular movie)" do
      item =
        build_media_item("movie", %{
          genres: ["Drama", "Crime"],
          origin_country: ["US"],
          original_language: "en"
        })

      assert CategoryClassifier.classify(item) == :movie
    end

    test "classifies Attack on Titan (anime series)" do
      item =
        build_media_item("tv_show", %{
          genres: ["Animation", "Action & Adventure", "Sci-Fi & Fantasy"],
          origin_country: ["JP"],
          original_language: "ja"
        })

      assert CategoryClassifier.classify(item) == :anime_series
    end

    test "classifies The Simpsons (cartoon series)" do
      item =
        build_media_item("tv_show", %{
          genres: ["Animation", "Comedy"],
          origin_country: ["US"],
          original_language: "en"
        })

      assert CategoryClassifier.classify(item) == :cartoon_series
    end

    test "classifies Breaking Bad (regular TV show)" do
      item =
        build_media_item("tv_show", %{
          genres: ["Drama", "Crime"],
          origin_country: ["US"],
          original_language: "en"
        })

      assert CategoryClassifier.classify(item) == :tv_show
    end

    test "classifies anime with only Anime genre from TVDB" do
      # TVDB native Anime genre without Animation
      item = build_media_item("tv_show", %{genres: ["Anime", "Action"]})
      assert CategoryClassifier.classify(item) == :anime_series
    end
  end

  describe "TVDB three-letter codes" do
    test "classifies a TVDB-shaped series as anime without an Anime genre" do
      metadata = %{
        genres: ["Animation", "Action"],
        origin_country: ["jpn"],
        original_language: "jpn"
      }

      assert CategoryClassifier.classify_from_metadata(:tv_show, metadata) == :anime_series
    end

    test "accepts an uppercase alpha-3 country code" do
      metadata = %{genres: ["Animation"], origin_country: ["JPN"]}

      assert CategoryClassifier.japanese_origin?(metadata)
    end

    test "still treats a non-Japanese cartoon as a cartoon" do
      metadata = %{
        genres: ["Animation"],
        origin_country: ["usa"],
        original_language: "eng"
      }

      assert CategoryClassifier.classify_from_metadata(:tv_show, metadata) == :cartoon_series
    end
  end
end
