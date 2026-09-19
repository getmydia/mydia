defmodule Mydia.P2p.SessionFileErrorTest do
  use ExUnit.Case, async: true

  alias Mydia.P2p.Server

  test "a bitmap subtitle still being copied answers 503, which the player polls through" do
    assert {503, _message} = Server.session_file_error(:pending)
  end

  test "a failed copy answers 415" do
    assert {415, _message} = Server.session_file_error(:extraction_failed)
  end

  test "the existing answers are unchanged" do
    assert {403, "Forbidden"} = Server.session_file_error(:path_traversal)

    assert {415, "Image-based subtitles cannot be converted to text"} =
             Server.session_file_error(:image_subtitle)

    assert {404, "Not found"} = Server.session_file_error(:not_image_track)
    assert {404, "Not found"} = Server.session_file_error(:media_file_not_found)
  end
end
