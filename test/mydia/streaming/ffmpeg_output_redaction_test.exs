defmodule Mydia.Streaming.FfmpegOutputRedactionTest do
  # A presigned URL echoed by ffmpeg can be split across two port messages at
  # any byte, including inside the X-Amz query. Redacting each message on its
  # own misses the continuation, so the transcoder must redact complete lines
  # at every point text leaves the process.
  #
  # Same blocked-stdin setup as ffmpeg_exit_catchup_test.exs: the real ffmpeg
  # never exits by itself, and the test injects port messages.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Mydia.Streaming.FfmpegHlsTranscoder

  @moduletag :requires_ffmpeg

  if is_nil(System.find_executable("ffmpeg")) do
    @moduletag skip: "ffmpeg not found on PATH"
  end

  @head "Error opening input http://127.0.0.1:9000/bucket/film.mkv?X-Amz-Algor"
  @tail "ithm=AWS4-HMAC-SHA256&X-Amz-Signature=deadbeefcafe&X-Amz-Credential=key\n"

  setup do
    # The suite runs at :warning; the per-line FFmpeg log is debug.
    previous = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous) end)

    dir = Path.join(System.tmp_dir!(), "hls_redaction_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp start_blocked_transcoder(dir) do
    test_pid = self()

    {:ok, pid} =
      FfmpegHlsTranscoder.start_transcoding(
        input_path: "pipe:0",
        output_dir: dir,
        on_error: fn msg -> send(test_pid, {:on_error, msg}) end,
        on_hwaccel_failed: fn out -> send(test_pid, {:on_hwaccel_failed, out}) end
      )

    on_exit(fn ->
      if Process.alive?(pid), do: FfmpegHlsTranscoder.stop_transcoding(pid)
    end)

    pid
  end

  defp port_of(pid), do: :sys.get_state(pid).ffmpeg_port

  defp refute_leaks(text), do: refute(text =~ "X-Amz-" or text =~ "deadbeef")

  test "a URL split inside the query never reaches a log line or on_error", %{dir: dir} do
    pid = start_blocked_transcoder(dir)
    port = port_of(pid)

    log =
      capture_log([level: :debug], fn ->
        send(pid, {port, {:data, @head}})
        send(pid, {port, {:data, @tail}})
        :sys.get_state(pid)
      end)

    refute_leaks(log)
    assert log =~ "http://127.0.0.1:9000/bucket/film.mkv"

    assert_receive {:on_error, message}, 1_000
    refute_leaks(message)
    assert message =~ "Error opening input"
  end

  test "the exit path flushes the buffered output redacted", %{dir: dir} do
    pid = start_blocked_transcoder(dir)
    port = port_of(pid)
    Process.flag(:trap_exit, true)

    # No trailing newline, so the continuation is still a partial line at exit.
    partial_tail = String.trim_trailing(@tail)

    log =
      capture_log([level: :debug], fn ->
        send(pid, {port, {:data, "unrelated chatter\n" <> @head}})
        send(pid, {port, {:data, partial_tail}})
        send(pid, {port, {:exit_status, 1}})
        Process.sleep(200)
      end)

    refute_leaks(log)

    for _ <- 1..3 do
      receive do
        {:on_error, message} -> refute_leaks(message)
      after
        100 -> :ok
      end
    end
  end

  test "the process status printed by crash reports holds no presigned query", %{dir: dir} do
    pid = start_blocked_transcoder(dir)
    port = port_of(pid)

    # Unterminated, so it stays in the raw carry-over field.
    send(pid, {port, {:data, @head}})
    assert :sys.get_state(pid).pending_line =~ "X-Amz-"

    refute inspect(:sys.get_status(pid), limit: :infinity) =~ "X-Amz-"
  end

  test "on_hwaccel_failed receives redacted output", %{dir: dir} do
    pid = start_blocked_transcoder(dir)
    port = port_of(pid)
    :sys.replace_state(pid, fn state -> %{state | accel_tier: :vaapi} end)

    capture_log([level: :debug], fn ->
      send(pid, {port, {:data, "Failed to initialise VAAPI connection\n" <> @head}})
      send(pid, {port, {:data, @tail}})
      send(pid, {port, {:exit_status, 1}})
      Process.sleep(200)
    end)

    assert_receive {:on_hwaccel_failed, output}, 1_000
    refute_leaks(output)
    assert output =~ "Failed to initialise VAAPI connection"
  end
end
