defmodule Mydia.Library.SegmentDetection.FingerprintTest do
  # Mutates Application env to swap the implementation, so serial.
  use ExUnit.Case, async: false

  alias Mydia.Library.SegmentDetection.Fingerprint
  alias Mydia.Library.SegmentDetection.Fingerprint.Result

  defmodule StubImpl do
    @moduledoc false

    @behaviour Mydia.Library.SegmentDetection.Fingerprint

    alias Mydia.Library.SegmentDetection.Fingerprint.Result

    @impl true
    def available?, do: true

    @impl true
    def fingerprint(path, start_s, length_s) do
      send(self(), {:fingerprinted, path, start_s, length_s})

      {:ok, %Result{hashes: [1, 2, 3], frame_ms: 124.17, window_start_ms: round(start_s * 1000)}}
    end
  end

  setup do
    on_exit(fn -> Application.delete_env(:mydia, :fingerprint_impl) end)

    :ok
  end

  describe "impl/0" do
    test "defaults to the fpcalc implementation" do
      assert Fingerprint.impl() == Mydia.Library.SegmentDetection.Fingerprint.Fpcalc
    end

    test "resolves the configured implementation" do
      Application.put_env(:mydia, :fingerprint_impl, StubImpl)

      assert Fingerprint.impl() == StubImpl
    end
  end

  describe "delegation" do
    setup do
      Application.put_env(:mydia, :fingerprint_impl, StubImpl)
    end

    test "fingerprint/3 forwards the window to the configured implementation" do
      assert {:ok, %Result{window_start_ms: 30_000}} =
               Fingerprint.fingerprint("/media/episode.mkv", 30, 600)

      assert_received {:fingerprinted, "/media/episode.mkv", 30, 600}
    end

    test "available?/0 forwards to the configured implementation" do
      assert Fingerprint.available?()
    end
  end
end
