defmodule Mydia.Streaming.KeyframeLocatorTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Mydia.Streaming.KeyframeLocator

  defp value_after(args, flag) do
    case Enum.find_index(args, &(&1 == flag)) do
      nil -> nil
      index -> Enum.at(args, index + 1)
    end
  end

  describe "parse/1" do
    test "reads the timestamp of a keyframe packet" do
      assert KeyframeLocator.parse("20.000000,K__\n") == {:ok, 20.0}
    end

    test "a packet that is not a keyframe is no answer" do
      # What an MPEG-TS source returns: no seek index, so ffprobe lands mid-GOP.
      assert KeyframeLocator.parse("26.983000,___,\n") == :none
    end

    test "skips stderr noise ahead of the packet line" do
      output = "[matroska,webm @ 0x55d0] Some warning\n33.366667,K__\n"

      assert KeyframeLocator.parse(output) == {:ok, 33.366667}
    end

    test "empty output is no answer" do
      assert KeyframeLocator.parse("") == :none
    end

    test "a timestamp ffprobe could not compute is no answer" do
      assert KeyframeLocator.parse("N/A,K__\n") == :none
    end
  end

  describe "locate/3" do
    test "asks for one packet of the first real video stream at the offset" do
      test_pid = self()

      runner = fn _name, args, _timeout ->
        send(test_pid, {:args, args})
        {:ok, "20.000000,K__\n"}
      end

      assert KeyframeLocator.locate("/lib/resume.mkv", 27, runner) == {:ok, 20.0}

      assert_received {:args, args}
      assert value_after(args, "-read_intervals") == "27%+#1"
      # V, not v: the transcoder maps 0:V:0?, which skips attached cover art.
      assert value_after(args, "-select_streams") == "V:0"
      assert List.last(args) == "/lib/resume.mkv"
    end

    test "bounds the lookup at 1.5s" do
      test_pid = self()

      runner = fn _name, _args, timeout ->
        send(test_pid, {:timeout, timeout})
        {:ok, "20.000000,K__\n"}
      end

      KeyframeLocator.locate("/lib/resume.mkv", 27, runner)

      assert_received {:timeout, 1_500}
    end

    test "a timeout is no answer, and is logged" do
      runner = fn _name, _args, _timeout -> {:error, :timeout} end

      log =
        capture_log(fn ->
          assert KeyframeLocator.locate("/lib/resume.mkv", 27, runner) == :none
        end)

      assert log =~ "timed out"
    end

    test "a failed or missing ffprobe is no answer" do
      assert KeyframeLocator.locate("/lib/resume.mkv", 27, fn _, _, _ -> {:error, :not_found} end) ==
               :none

      assert KeyframeLocator.locate("/lib/resume.mkv", 27, fn _, _, _ ->
               {:error, {:exit, 1, "Invalid data found when processing input"}}
             end) == :none
    end
  end
end
