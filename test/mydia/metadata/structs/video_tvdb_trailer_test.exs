defmodule Mydia.Metadata.Structs.VideoTvdbTrailerTest do
  use ExUnit.Case, async: true

  alias Mydia.Metadata.Structs.Video

  # A real TVDB trailer entry, as returned by /series/{id}/extended. TVDB
  # carries no type/official/published_at fields.
  defp trailer(attrs) do
    Map.merge(
      %{"id" => 204_863, "language" => "eng", "name" => "Trailer", "runtime" => 0},
      attrs
    )
  end

  describe "from_tvdb_trailer/1" do
    test "parses a youtube watch URL" do
      assert {:ok, video} =
               Video.from_tvdb_trailer(
                 trailer(%{"url" => "https://www.youtube.com/watch?v=M1bhOaLV4FU"})
               )

      assert video.key == "M1bhOaLV4FU"
      assert video.site == "YouTube"
      assert video.type == "Trailer"
      assert video.name == "Trailer"
      assert video.id == "204863"
    end

    test "parses a youtu.be short URL" do
      assert {:ok, video} =
               Video.from_tvdb_trailer(trailer(%{"url" => "https://youtu.be/M1bhOaLV4FU"}))

      assert video.key == "M1bhOaLV4FU"
    end

    test "parses a youtube embed URL" do
      assert {:ok, video} =
               Video.from_tvdb_trailer(
                 trailer(%{"url" => "https://www.youtube.com/embed/M1bhOaLV4FU"})
               )

      assert video.key == "M1bhOaLV4FU"
    end

    test "rejects a non-YouTube URL" do
      assert :error = Video.from_tvdb_trailer(trailer(%{"url" => "https://vimeo.com/123456"}))
    end

    test "rejects a malformed URL" do
      assert :error = Video.from_tvdb_trailer(trailer(%{"url" => "not a url"}))
    end

    test "rejects a trailer with no url" do
      assert :error = Video.from_tvdb_trailer(%{"id" => 1, "name" => "Trailer"})
    end

    test "tolerates a missing id" do
      assert {:ok, video} =
               Video.from_tvdb_trailer(%{
                 "name" => "Trailer",
                 "url" => "https://www.youtube.com/watch?v=M1bhOaLV4FU"
               })

      assert video.id == nil
    end
  end

  describe "from_tvdb_trailers/2" do
    test "returns an empty list for nil and empty input" do
      assert Video.from_tvdb_trailers(nil, ["eng"]) == []
      assert Video.from_tvdb_trailers([], ["eng"]) == []
    end

    test "drops entries that cannot be parsed" do
      videos =
        Video.from_tvdb_trailers(
          [
            trailer(%{"url" => "https://vimeo.com/123456"}),
            trailer(%{"url" => "https://www.youtube.com/watch?v=keepme"})
          ],
          ["eng"]
        )

      assert Enum.map(videos, & &1.key) == ["keepme"]
    end

    test "sorts preferred-language entries ahead of the rest" do
      videos =
        Video.from_tvdb_trailers(
          [
            trailer(%{"language" => "pt", "url" => "https://www.youtube.com/watch?v=ptkey"}),
            trailer(%{"language" => "eng", "url" => "https://www.youtube.com/watch?v=engkey"})
          ],
          ["eng", "en"]
        )

      assert Enum.map(videos, & &1.key) == ["engkey", "ptkey"]
    end

    test "preserves input order within the same language" do
      videos =
        Video.from_tvdb_trailers(
          [
            trailer(%{"language" => "eng", "url" => "https://www.youtube.com/watch?v=first"}),
            trailer(%{"language" => "eng", "url" => "https://www.youtube.com/watch?v=second"})
          ],
          ["eng"]
        )

      assert Enum.map(videos, & &1.key) == ["first", "second"]
    end

    test "keeps unmatched languages rather than dropping them" do
      videos =
        Video.from_tvdb_trailers(
          [trailer(%{"language" => "spa", "url" => "https://www.youtube.com/watch?v=spakey"})],
          ["eng"]
        )

      assert Enum.map(videos, & &1.key) == ["spakey"]
    end
  end
end
