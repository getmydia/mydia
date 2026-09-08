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

    test "a bare ENOSYS string with no VAAPI context is not a hardware failure" do
      # "Function not implemented" is the literal strerror(ENOSYS) text ffmpeg
      # prints for ANY AVERROR(ENOSYS) -- an unsupported muxer, protocol, or
      # codec feature, not only hardware device init. Matching it standalone
      # would retry an unrelated encode-time ENOSYS in software, hiding a real
      # bug behind a second, slower failure. Paired with the test above ("an
      # unimplemented driver function"), which proves the real VAAPI case
      # (the same text inside the connection line) is still caught.
      refute FfmpegHlsTranscoder.hwaccel_failure?("Function not implemented")
    end
  end

  describe "append_output/2" do
    test "leaves a buffer under the cap untouched" do
      assert FfmpegHlsTranscoder.append_output("", "short") == "short"
      assert FfmpegHlsTranscoder.append_output("abc", "def") == "abcdef"
    end

    test "bounds cumulative multi-byte input to the byte cap, not the grapheme cap" do
      # Regression for a defect where the bound was applied with
      # String.slice/3, which counts grapheme clusters: a buffer of 3-byte
      # UTF-8 characters (CJK is realistic here -- this is a self-hosted
      # media server with arbitrary international file paths) sliced to
      # "the last 4,000" kept 4,000 *characters*, up to 3x the intended byte
      # cap.
      chunk = String.duplicate("界", 1_000)

      buffer =
        Enum.reduce(1..5, "", fn _, acc -> FfmpegHlsTranscoder.append_output(acc, chunk) end)

      assert byte_size(buffer) <= 4_000
    end

    test "keeps the most recent bytes when trimming" do
      buffer = FfmpegHlsTranscoder.append_output(String.duplicate("a", 4_990), "MARKER_END")

      assert byte_size(buffer) == 4_000
      assert String.ends_with?(buffer, "MARKER_END")
    end
  end
end
