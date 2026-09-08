defmodule Mydia.Streaming.HwaccelFailureClassifierTest do
  use ExUnit.Case, async: true

  alias Mydia.Streaming.FfmpegHlsTranscoder

  describe "hwaccel_failure?/1" do
    test "the driver-less container failure, captured from production" do
      output = """
      [VAAPI @ 0x75537df49d40] Failed to initialise VAAPI connection: -1 (unknown libva error).
      Device creation failed: -5.
      Failed to set value 'vaapi=hw:/dev/dri/renderD128' for option 'init_hw_device': I/O error
      Error parsing global options: I/O error
      """

      assert FfmpegHlsTranscoder.hwaccel_failure?(output)
    end

    test "no VA display" do
      assert FfmpegHlsTranscoder.hwaccel_failure?(
               "[AVHWDeviceContext] No VA display found for device /dev/dri/renderD128."
             )
    end

    test "an unimplemented driver function" do
      assert FfmpegHlsTranscoder.hwaccel_failure?(
               "Failed to initialise VAAPI connection: -1 (Function not implemented)."
             )
    end

    test "permission denied on the render node" do
      assert FfmpegHlsTranscoder.hwaccel_failure?(
               "Failed to open /dev/dri/renderD128: Permission denied"
             )
    end

    test "an ordinary encode error is not a hardware failure" do
      # Falling back to software here would hide a real bug behind a slow
      # transcode that also fails.
      refute FfmpegHlsTranscoder.hwaccel_failure?("Invalid data found when processing input")
      refute FfmpegHlsTranscoder.hwaccel_failure?("height not divisible by 2")
      refute FfmpegHlsTranscoder.hwaccel_failure?("No such file or directory")
    end
  end
end
