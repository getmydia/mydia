defmodule Mydia.Library.Structs.FileMetadataTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.Structs.{FileMetadata, StreamInfo}

  describe "streams round trip" do
    test "survives to_map then from_map" do
      metadata = %FileMetadata{
        duration: 9780.0,
        container: "mkv",
        streams: [
          %StreamInfo{index: 0, type: :video, codec: "hevc", width: 3840, height: 2160},
          %StreamInfo{index: 1, type: :audio, codec: "truehd", channels: 8, is_default: true}
        ]
      }

      restored = metadata |> FileMetadata.to_map() |> FileMetadata.from_map()

      assert restored.duration == 9780.0
      assert restored.container == "mkv"
      assert length(restored.streams) == 2
      assert Enum.at(restored.streams, 0).type == :video
      assert Enum.at(restored.streams, 0).width == 3840
      assert Enum.at(restored.streams, 1).codec == "truehd"
      assert Enum.at(restored.streams, 1).is_default == true
    end

    test "survives a JSON encode and decode cycle" do
      metadata = %FileMetadata{
        streams: [%StreamInfo{index: 0, type: :subtitle, codec: "subrip", language: "eng"}]
      }

      restored =
        metadata
        |> FileMetadata.to_map()
        |> Jason.encode!()
        |> Jason.decode!()
        |> FileMetadata.from_map()

      assert [%StreamInfo{type: :subtitle, codec: "subrip", language: "eng"}] = restored.streams
    end

    test "keeps nil distinct from an empty list" do
      assert FileMetadata.from_map(FileMetadata.to_map(%FileMetadata{streams: nil})).streams ==
               nil

      assert FileMetadata.from_map(FileMetadata.to_map(%FileMetadata{streams: []})).streams == []
    end

    test "accepts a list of structs directly, as the analyzer supplies them" do
      restored = FileMetadata.from_map(%{"streams" => [%StreamInfo{index: 0, type: :video}]})
      assert [%StreamInfo{index: 0, type: :video}] = restored.streams
    end

    test "an empty metadata map still has nil streams" do
      assert FileMetadata.empty().streams == nil
    end

    test "drops malformed stream entries instead of raising" do
      # This runs on every metadata load, so one bad entry in a hand-edited or
      # legacy JSON column must cost that stream, not crash reads and repairs
      # for the whole file.
      restored =
        FileMetadata.from_map(%{
          "streams" => [
            %{"type" => "video", "codec" => "h264"},
            nil,
            "not a stream",
            42,
            %{"type" => "audio", "codec" => "aac"}
          ]
        })

      assert [
               %StreamInfo{type: :video, codec: "h264"},
               %StreamInfo{type: :audio, codec: "aac"}
             ] = restored.streams
    end
  end
end
