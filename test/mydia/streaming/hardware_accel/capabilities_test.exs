defmodule Mydia.Streaming.HardwareAccel.CapabilitiesTest do
  use ExUnit.Case, async: true

  alias Mydia.Streaming.HardwareAccel.Capabilities

  describe "software/1" do
    test "carries the reason so the settings page can explain itself" do
      caps = Capabilities.software("no render node present")

      assert caps.backend == :none
      assert caps.device == nil
      assert caps.reason == "no render node present"
      refute Capabilities.accelerated?(caps)
    end
  end

  describe "can_decode?/2" do
    test "matches a codec the device advertises" do
      caps = %Capabilities{backend: :vaapi, decode_profiles: [:hevc, :av1]}

      assert Capabilities.can_decode?(caps, :hevc)
      assert Capabilities.can_decode?(caps, "av1")
      refute Capabilities.can_decode?(caps, :vp9)
    end

    test "an unknown codec string is not a decode profile" do
      # A source codec ffprobe reported but we have no atom for must never
      # resolve to a hardware decode path, and must never mint an atom.
      caps = %Capabilities{backend: :vaapi, decode_profiles: [:hevc]}

      refute Capabilities.can_decode?(caps, "prores_raw_9000")
      refute Capabilities.can_decode?(caps, nil)
    end

    test "software capabilities decode nothing" do
      refute Capabilities.can_decode?(Capabilities.software("off"), :hevc)
    end
  end

  describe "can_encode?/2" do
    test "reflects the advertised encoders" do
      caps = %Capabilities{backend: :vaapi, encoders: [:h264]}

      assert Capabilities.can_encode?(caps, :h264)
      refute Capabilities.can_encode?(caps, :hevc)
    end
  end
end
