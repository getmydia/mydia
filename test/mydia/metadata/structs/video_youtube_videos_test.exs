defmodule Mydia.Metadata.Structs.VideoYoutubeVideosTest do
  use ExUnit.Case, async: true

  alias Mydia.Metadata.Structs.Video

  test "keeps YouTube videos with a key, in order" do
    a = %Video{key: "a", site: "YouTube"}
    b = %Video{key: "b", site: "YouTube"}
    vimeo = %Video{key: "v", site: "Vimeo"}

    assert Video.youtube_videos([a, vimeo, b]) == [a, b]
  end

  test "drops entries without a binary key" do
    assert Video.youtube_videos([%Video{key: nil, site: "YouTube"}]) == []
  end

  test "is empty for nil" do
    assert Video.youtube_videos(nil) == []
  end
end
