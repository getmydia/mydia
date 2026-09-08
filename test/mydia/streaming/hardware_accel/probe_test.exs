defmodule Mydia.Streaming.HardwareAccel.ProbeTest do
  use ExUnit.Case, async: true

  alias Mydia.Streaming.HardwareAccel.Capabilities
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

    test "a device that exists but is not a working render node reports its own failure, not a generic one" do
      # File.touch!/1 creates something that satisfies File.exists?/1 but is
      # not a real render node, so vainfo (or, absent that binary, the
      # rescue ErlangError clause) fails on it. In this devenv vainfo is not
      # installed, so this also exercises the boot-safety path where
      # System.cmd/3 raises: the probe must degrade to software capabilities
      # rather than crash the caller.
      tmp_path = Path.join(System.tmp_dir!(), "probe_test_#{System.unique_integer([:positive])}")
      File.touch!(tmp_path)
      on_exit(fn -> File.rm(tmp_path) end)

      caps = Probe.run(hwaccel: :vaapi, device: tmp_path)

      assert %Capabilities{backend: :none} = caps
      # The reason names this specific device and its actual failure, not the
      # generic "no usable VAAPI device among ..." that discards which device
      # failed and why.
      assert caps.reason =~ tmp_path
      refute caps.reason =~ "no usable VAAPI device among"
    end
  end

  describe "run_bounded/3" do
    test "returns the child's combined output on a normal exit" do
      assert {:ok, output} = Probe.run_bounded("echo", ["hello"])
      assert String.trim(output) == "hello"
    end

    test "reports the exit code and output on a non-zero exit" do
      assert {:error, {:exit, 7, _output}} = Probe.run_bounded("sh", ["-c", "exit 7"])
    end

    test "reports :not_found for a missing executable" do
      assert {:error, :not_found} =
               Probe.run_bounded("definitely-not-a-real-mydia-probe-binary", [])
    end

    test "a wedged command times out instead of blocking the caller" do
      started_at = System.monotonic_time(:millisecond)

      assert {:error, :timeout} = Probe.run_bounded("sleep", ["5"], 100)

      elapsed = System.monotonic_time(:millisecond) - started_at
      # Generous margin over the 100ms bound: the assertion that matters is
      # "did not wait anywhere near sleep's actual 5s", not a tight bound on
      # scheduler jitter.
      assert elapsed < 2_000
    end

    test "the timeout actually kills the OS process rather than abandoning it" do
      # A fingerprinted duration so pgrep -f finds only the child this call
      # spawned, never some unrelated sleep left over by another test running
      # concurrently (this module is async: true).
      unique_secs = to_string(100_000 + System.unique_integer([:positive]))

      assert {:error, :timeout} = Probe.run_bounded("sleep", [unique_secs], 100)

      # The SIGKILL in kill_bounded/2 is sent synchronously before
      # run_bounded/3 returns, but the kernel reaping it is not instant.
      Process.sleep(200)

      case System.find_executable("pgrep") do
        nil ->
          :ok

        _found ->
          {output, _status} =
            System.cmd("pgrep", ["-f", "sleep #{unique_secs}"], stderr_to_stdout: true)

          assert String.trim(output) == "",
                 "sleep #{unique_secs} was still running after its timeout killed it"
      end
    end
  end
end
