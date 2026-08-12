defmodule Mydia.Streaming.ActiveSessionsTest do
  use Mydia.DataCase, async: true

  alias Mydia.Streaming.ActiveSession

  test "the struct carries the fields the now-playing card needs" do
    session = %ActiveSession{}

    assert Map.has_key?(session, :media_file_id)
    assert Map.has_key?(session, :bitrate_bps)
    assert Map.has_key?(session, :position_seconds)
    assert Map.has_key?(session, :duration_seconds)
  end
end
