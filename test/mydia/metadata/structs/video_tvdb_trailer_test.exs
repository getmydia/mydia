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

    test "parses a youtube /v/ URL" do
      assert {:ok, video} =
               Video.from_tvdb_trailer(
                 trailer(%{"url" => "https://www.youtube.com/v/M1bhOaLV4FU"})
               )

      assert video.key == "M1bhOaLV4FU"
    end

    test "parses a youtube /shorts/ URL" do
      assert {:ok, video} =
               Video.from_tvdb_trailer(
                 trailer(%{"url" => "https://www.youtube.com/shorts/M1bhOaLV4FU"})
               )

      assert video.key == "M1bhOaLV4FU"
    end

    test "parses a mixed-case scheme and host" do
      # URI.parse/1 does not normalize the host, and TVDB trailer URLs are
      # user-contributed, so mixed case must still match.
      assert {:ok, video} =
               Video.from_tvdb_trailer(
                 trailer(%{"url" => "HTTPS://WWW.YouTube.com/watch?v=M1bhOaLV4FU"})
               )

      assert video.key == "M1bhOaLV4FU"

      assert {:ok, short} =
               Video.from_tvdb_trailer(trailer(%{"url" => "HTTPS://YOUTU.BE/M1bhOaLV4FU"}))

      assert short.key == "M1bhOaLV4FU"
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

    test "tolerates a non-scalar id rather than raising" do
      # to_string/1 raises Protocol.UndefinedError for a map, and nothing between
      # here and the TVDB fetch rescues it, so a malformed id must not blow up.
      assert {:ok, video} =
               Video.from_tvdb_trailer(%{
                 "id" => %{"unexpected" => "shape"},
                 "url" => "https://www.youtube.com/watch?v=M1bhOaLV4FU"
               })

      assert video.id == nil

      assert {:ok, list_id} =
               Video.from_tvdb_trailer(%{
                 "id" => [1, 2],
                 "url" => "https://www.youtube.com/watch?v=M1bhOaLV4FU"
               })

      assert list_id.id == nil
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

    test "caps the result at 5 to match MediaMetadata.parse_videos/1" do
      # The Boys carries 11 trailers on TVDB; TVDB-sourced items must not
      # persist a longer list than TMDB-sourced ones.
      trailers =
        for n <- 1..11 do
          trailer(%{"language" => "eng", "url" => "https://www.youtube.com/watch?v=key#{n}"})
        end

      videos = Video.from_tvdb_trailers(trailers, ["eng"])

      assert length(videos) == 5
      assert Enum.map(videos, & &1.key) == ["key1", "key2", "key3", "key4", "key5"]
    end

    test "applies the cap after the language sort, not before" do
      trailers =
        for n <- 1..6 do
          language = if n == 6, do: "eng", else: "spa"
          trailer(%{"language" => language, "url" => "https://www.youtube.com/watch?v=key#{n}"})
        end

      videos = Video.from_tvdb_trailers(trailers, ["eng"])

      assert length(videos) == 5
      assert List.first(videos).key == "key6"
    end
  end
end
