defmodule Mydia.Streaming.HlsSessionOffsetTest do
  use ExUnit.Case, async: true

  alias Mydia.Streaming.HlsSessionSupervisor

  describe "session_matches_offset?/2" do
    test "matches when the requested offset equals the running one" do
      assert HlsSessionSupervisor.session_matches_offset?(%{start_position: 600}, 600)
    end

    test "does not match a different offset" do
      refute HlsSessionSupervisor.session_matches_offset?(%{start_position: 0}, 4200)
    end

    test "treats metadata with no start_position as offset zero" do
      # Registry metadata is in-memory, but a session registered before this
      # field existed must not be mistaken for an offset session.
      assert HlsSessionSupervisor.session_matches_offset?(%{mode: :transcode}, 0)
      refute HlsSessionSupervisor.session_matches_offset?(%{mode: :transcode}, 4200)
    end
  end
end
