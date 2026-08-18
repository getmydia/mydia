defmodule Mydia.Library.PathAnchorTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.PathAnchor

  @root "/media/Series"

  describe "classify_segment/1" do
    test "season folders" do
      assert PathAnchor.classify_segment("Season 01") == {:season, 1}
      assert PathAnchor.classify_segment("S02") == {:season, 2}
      assert PathAnchor.classify_segment("Specials") == {:season, 0}
    end

    test "disc folders" do
      assert PathAnchor.classify_segment("Disc 1") == :disc
      assert PathAnchor.classify_segment("CD2") == :disc
      assert PathAnchor.classify_segment("BDMV") == :disc
      assert PathAnchor.classify_segment("VIDEO_TS") == :disc
    end

    test "quality folders" do
      assert PathAnchor.classify_segment("1080p") == :quality
      assert PathAnchor.classify_segment("2160p") == :quality
      assert PathAnchor.classify_segment("BluRay") == :quality
    end

    test "anything else is a title" do
      assert PathAnchor.classify_segment("Breaking Bad") == :title
      assert PathAnchor.classify_segment("Passe-Partout (2018)") == :title
    end
  end

  describe "normalize/1" do
    test "strips year, provider tags, punctuation and case" do
      assert PathAnchor.normalize("Passe-Partout (2018)") == "passe partout"
      assert PathAnchor.normalize("The Matrix [tmdb-603]") == "the matrix"
      assert PathAnchor.normalize("Breaking.Bad") == "breaking bad"
      assert PathAnchor.normalize("  Cornemuse   ") == "cornemuse"
    end
  end

  describe "anchor_for/2" do
    test "climbs past a season folder to the series folder" do
      path = "#{@root}/Cornemuse (1999)/Season 02/Cornemuse (1999) - S02E01.mkv"

      assert %{
               anchor_path: "Cornemuse (1999)",
               cluster_key: "cornemuse",
               season_hint: 2,
               climbed: [{:season, 2}]
             } = PathAnchor.anchor_for(path, @root)
    end

    test "uses the immediate parent when there is no season folder" do
      path = "#{@root}/Show Name/ep.mkv"

      assert %{anchor_path: "Show Name", cluster_key: "show name", season_hint: nil} =
               PathAnchor.anchor_for(path, @root)
    end

    test "climbs past disc and quality folders too" do
      path = "#{@root}/The Wire/Season 01/1080p/Disc 2/ep.mkv"

      assert %{anchor_path: "The Wire", season_hint: 1} = PathAnchor.anchor_for(path, @root)
    end

    test "climbs past a redundant release folder that repeats its parent" do
      path = "#{@root}/The Wire/The.Wire.S01.1080p.BluRay/Season 01/ep.mkv"

      assert %{anchor_path: "The Wire", cluster_key: "the wire"} =
               PathAnchor.anchor_for(path, @root)
    end

    test "never climbs past the library root" do
      path = "#{@root}/Season 01/ep.mkv"

      assert %{anchor_path: "Season 01", cluster_key: "season 01", season_hint: nil} =
               PathAnchor.anchor_for(path, @root)
    end

    test "a file sitting directly in the library root is a loose file" do
      assert %{anchor_path: "", cluster_key: "__root__", season_hint: nil} =
               PathAnchor.anchor_for("#{@root}/movie.mkv", @root)
    end

    test "rejects a denylisted folder name as an anchor" do
      assert %{anchor_path: "", cluster_key: "__root__"} =
               PathAnchor.anchor_for("/media/media/x.mkv", "/media")
    end

    test "climbs past a dot-prefixed invalid-title folder to the parent anchor" do
      path = "#{@root}/Show Name/.hidden/ep.mkv"

      assert %{
               anchor_path: "Show Name",
               cluster_key: "show name",
               season_hint: nil,
               climbed: [:invalid_title]
             } = PathAnchor.anchor_for(path, @root)
    end

    test "does not climb past a nested title that does not repeat its parent" do
      path = "#{@root}/Anime/One Piece/Season 1/ep.mkv"

      assert %{
               anchor_path: "Anime/One Piece",
               cluster_key: "one piece",
               season_hint: 1,
               climbed: [{:season, 1}]
             } = PathAnchor.anchor_for(path, @root)
    end
  end
end
