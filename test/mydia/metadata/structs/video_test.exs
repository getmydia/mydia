defmodule Mydia.Metadata.Structs.VideoTest do
  use ExUnit.Case, async: true

  alias Mydia.Metadata.Structs.Video

  describe "youtube_watch_url/1" do
    test "builds a watch URL for a YouTube video" do
      video = %Video{key: "dQw4w9WgXcQ", site: "YouTube"}

      assert Video.youtube_watch_url(video) == "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
    end

    test "returns nil for a non-YouTube video" do
      video = %Video{key: "abc123", site: "Vimeo"}

      assert Video.youtube_watch_url(video) == nil
    end

    test "returns nil for nil" do
      assert Video.youtube_watch_url(nil) == nil
    end
  end
end
