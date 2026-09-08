defmodule Mydia.Streaming.HardwareAccel.ProbeTest do
  use ExUnit.Case, async: true

  alias Mydia.Streaming.HardwareAccel.Probe

  defp fixture(name), do: File.read!("test/support/fixtures/#{name}")

  describe "parse_vainfo/1" do
    test "reads decode profiles from VLD entrypoints" do
      %{decode_profiles: decode} = Probe.parse_vainfo(fixture("vainfo_intel_raptor_lake.txt"))

      assert :h264 in decode
      assert :hevc in decode
      assert :av1 in decode
      assert :vp9 in decode
      assert :vp8 in decode
      assert :mpeg2video in decode
      assert :vc1 in decode
    end

    test "reads encoders from EncSlice entrypoints" do
      %{encoders: encoders} = Probe.parse_vainfo(fixture("vainfo_intel_raptor_lake.txt"))

      assert :h264 in encoders
      assert :hevc in encoders
    end

    test "AV1 has no encode entrypoint on this device" do
      # Raptor Lake decodes AV1 and cannot encode it. Reading VLD as encode
      # support would pick an encoder that does not exist.
      %{encoders: encoders} = Probe.parse_vainfo(fixture("vainfo_intel_raptor_lake.txt"))

      refute :av1 in encoders
    end

    test "a driver-less vainfo yields nothing" do
      assert %{encoders: [], decode_profiles: []} =
               Probe.parse_vainfo(fixture("vainfo_no_driver.txt"))
    end

    test "results are deduplicated" do
      # H264High and H264Main both map to :h264 and both advertise EncSlice.
      %{encoders: encoders} = Probe.parse_vainfo(fixture("vainfo_intel_raptor_lake.txt"))

      assert length(encoders) == length(Enum.uniq(encoders))
    end
  end

  describe "run/1" do
    test "returns software capabilities when hwaccel is off" do
      caps = Probe.run(hwaccel: :off)

      assert caps.backend == :none
      assert caps.reason =~ "HWACCEL=off"
    end

    test "returns software capabilities when no render node exists" do
      caps = Probe.run(hwaccel: :auto, device_glob: "/nonexistent/renderD*")

      assert caps.backend == :none
      assert caps.reason =~ "no render node"
    end

    test "an explicitly requested device that does not exist is reported as such" do
      caps = Probe.run(hwaccel: :vaapi, device: "/nonexistent/renderD128")

      assert caps.backend == :none
      assert caps.reason =~ "/nonexistent/renderD128"
    end
  end
end
