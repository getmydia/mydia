defmodule Mydia.Media.ShowStatusTest do
  use ExUnit.Case, async: true

  alias Mydia.Media.MediaItem
  alias Mydia.Media.ShowStatus
  alias Mydia.Metadata.Structs.MediaMetadata

  describe "normalize/1" do
    for {raw, expected} <- [
          {"Returning Series", :continuing},
          {"Continuing", :continuing},
          {"Ended", :ended},
          {"Canceled", :canceled},
          {"Cancelled", :canceled},
          {"In Production", :upcoming},
          {"Planned", :upcoming},
          {"Pilot", :upcoming},
          {"Upcoming", :upcoming},
          {"Released", nil},
          {"Something New", nil},
          {"", nil},
          {nil, nil},
          {42, nil}
        ] do
      test "#{inspect(raw)} -> #{inspect(expected)}" do
        assert ShowStatus.normalize(unquote(raw)) == unquote(expected)
      end
    end
  end

  describe "for_item/1" do
    test "reads a show's metadata status" do
      item = %MediaItem{
        type: "tv_show",
        metadata: %MediaMetadata{
          provider_id: "1",
          provider: :tmdb,
          media_type: :tv_show,
          status: "Ended"
        }
      }

      assert ShowStatus.for_item(item) == :ended
    end

    test "is nil for a movie even with a TV-like status" do
      item = %MediaItem{
        type: "movie",
        metadata: %MediaMetadata{
          provider_id: "1",
          provider: :tmdb,
          media_type: :movie,
          status: "Ended"
        }
      }

      assert ShowStatus.for_item(item) == nil
    end

    test "is nil when metadata is missing or not a struct" do
      assert ShowStatus.for_item(%MediaItem{type: "tv_show", metadata: nil}) == nil

      assert ShowStatus.for_item(%MediaItem{type: "tv_show", metadata: %{"status" => "Ended"}}) ==
               nil

      assert ShowStatus.for_item(nil) == nil
    end
  end

  describe "for_metadata/1" do
    test "reads a TV metadata struct" do
      metadata = %MediaMetadata{
        provider_id: "1",
        provider: :tmdb,
        media_type: :tv_show,
        status: "Continuing"
      }

      assert ShowStatus.for_metadata(metadata) == :continuing
    end

    test "is nil for movie metadata and nil" do
      movie_metadata = %MediaMetadata{
        provider_id: "1",
        provider: :tmdb,
        media_type: :movie,
        status: "Ended"
      }

      assert ShowStatus.for_metadata(movie_metadata) == nil
      assert ShowStatus.for_metadata(nil) == nil
    end
  end

  test "label/1" do
    assert ShowStatus.label(:continuing) == "Continuing"
    assert ShowStatus.label(:ended) == "Ended"
    assert ShowStatus.label(:canceled) == "Canceled"
    assert ShowStatus.label(:upcoming) == "Upcoming"
  end
end
