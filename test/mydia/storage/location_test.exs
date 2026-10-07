defmodule Mydia.Storage.LocationTest do
  use ExUnit.Case, async: true

  alias Mydia.Storage.Location

  describe "parse_s3/1" do
    test "splits backend name and prefix, normalizing slashes" do
      assert Location.parse_s3("s3://media/movies") == {:ok, "media", "movies/"}
      assert Location.parse_s3("s3://media/movies/") == {:ok, "media", "movies/"}
      assert Location.parse_s3("s3://media//nested/dir") == {:ok, "media", "nested/dir/"}
    end

    test "an empty prefix means the bucket root" do
      assert Location.parse_s3("s3://media") == {:ok, "media", ""}
      assert Location.parse_s3("s3://media/") == {:ok, "media", ""}
    end

    test "rejects malformed and non-s3 paths" do
      assert Location.parse_s3("s3://") == :error
      assert Location.parse_s3("/data/movies") == :error
      assert Location.parse_s3("S3://media/x") == :error
    end
  end

  test "s3_path?/1" do
    assert Location.s3_path?("s3://media/movies")
    refute Location.s3_path?("/s3://nope")
    refute Location.s3_path?(nil)
  end

  test "key/2 joins prefix and relative path" do
    loc = Location.s3(%{name: "media"}, "movies/", "s3://media/movies")
    assert Location.key(loc, "Some Film (2031)/film.mkv") == "movies/Some Film (2031)/film.mkv"
    assert Location.key(Location.s3(%{name: "m"}, "", "s3://m"), "a.mkv") == "a.mkv"
  end
end
