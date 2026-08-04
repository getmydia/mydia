defmodule Mydia.Library.ContentProbe do
  @moduledoc """
  Classifies a file as media or not by reading its container headers.

  Used when a download's file was rejected on extension alone, so the operator
  can tell an obfuscated release (a Matroska file named `.bin`) from a fake one
  (a Windows executable named `.exe`). Reads headers only, so it is cheap even
  on multi-gigabyte files.
  """

  require Logger

  @timeout_ms 10_000

  @type verdict :: %{required(String.t()) => String.t()}

  @doc """
  Probes `path` and returns a verdict map with string keys, ready to store in
  the download's JSON metadata.

    * `%{"status" => "media", "detail" => "matroska,webm, 24:31, h264"}`
    * `%{"status" => "not_media", "detail" => "invalid data"}`
    * `%{"status" => "unknown", "detail" => "ffprobe not installed"}`
  """
  @spec probe(String.t()) :: verdict()
  def probe(path) when is_binary(path) do
    with {:ok, ffprobe} <- executable(),
         {:file, true} <- {:file, File.regular?(path)} do
      run(ffprobe, path)
    else
      {:error, :ffprobe_not_found} -> verdict("unknown", "ffprobe not installed")
      {:file, false} -> verdict("unknown", "file not found")
    end
  end

  defp executable do
    case System.find_executable("ffprobe") do
      nil -> {:error, :ffprobe_not_found}
      path -> {:ok, path}
    end
  end

  # Runs ffprobe through a Port we own directly (no Task), for two reasons:
  #
  #   * A `Task.async` result is linked to this process, so a raise inside the
  #     spawned function (e.g. ffprobe vanishing between `executable/0`'s check
  #     and invocation) would exit this process via a linked EXIT before the
  #     `rescue` below ever ran. A directly-opened port raises in this process,
  #     where `rescue` can actually catch it.
  #   * `Task.shutdown(:brutal_kill)` only kills the BEAM process that called
  #     `System.cmd/3` — it does not touch the ffprobe OS process `System.cmd`
  #     spawned, which survives, reparents to init, and keeps running. Opening
  #     our own port lets us capture the OS pid via `Port.info/2` and send it
  #     a real SIGKILL on timeout.
  defp run(ffprobe, path) do
    args = [
      "-v",
      "error",
      "-show_entries",
      "format=format_name,duration",
      "-show_entries",
      "stream=codec_type,codec_name",
      "-of",
      "default=noprint_wrappers=1",
      path
    ]

    port =
      Port.open({:spawn_executable, ffprobe}, [
        :binary,
        :exit_status,
        :hide,
        :stderr_to_stdout,
        args: args
      ])

    collect(port, port_os_pid(port), "")
  rescue
    exception ->
      Logger.warning("Content probe raised: #{Exception.message(exception)}")
      verdict("unknown", "probe failed")
  end

  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      nil -> nil
    end
  end

  defp collect(port, os_pid, acc) do
    receive do
      {^port, {:data, chunk}} -> collect(port, os_pid, acc <> chunk)
      {^port, {:exit_status, 0}} -> classify(acc)
      {^port, {:exit_status, _code}} -> verdict("not_media", first_line(acc))
    after
      @timeout_ms ->
        kill_and_close(port, os_pid)
        verdict("unknown", "probe timed out")
    end
  end

  # `Port.close/1` alone does not guarantee the OS process dies: it only
  # detaches Erlang's end of the stdio pipes. A process like ffprobe, which
  # reads its input from a file path (not stdin) and only writes to stdout
  # once done, never notices the pipe closing and keeps running as an orphan.
  # Verified empirically: closing the port left the ffprobe process alive and
  # still reading; sending SIGKILL to the OS pid from `Port.info/2` reliably
  # killed it. So we signal the pid directly instead of relying on close.
  defp kill_and_close(port, os_pid) do
    send_kill(os_pid)
    close_port(port)
    flush_port_messages(port)
  end

  defp send_kill(nil), do: :ok

  defp send_kill(os_pid) do
    System.cmd("kill", ["-KILL", to_string(os_pid)], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  defp close_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp flush_port_messages(port) do
    receive do
      {^port, _} -> flush_port_messages(port)
    after
      0 -> :ok
    end
  end

  defp classify(output) do
    fields = parse_fields(output)

    if Map.has_key?(fields, "format_name") and has_av_stream?(fields) do
      verdict("media", summarize(fields))
    else
      verdict("not_media", "no audio or video stream")
    end
  end

  defp parse_fields(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, "=", parts: 2) do
        [key, value] ->
          Map.update(acc, String.trim(key), [String.trim(value)], &[String.trim(value) | &1])

        _ ->
          acc
      end
    end)
    |> Map.new(fn {k, v} -> {k, Enum.reverse(v)} end)
    |> then(fn map ->
      Map.new(map, fn
        {"format_name", [first | _]} -> {"format_name", first}
        {"duration", [first | _]} -> {"duration", first}
        {k, v} -> {k, v}
      end)
    end)
  end

  defp has_av_stream?(fields) do
    types = Map.get(fields, "codec_type", [])
    "video" in types or "audio" in types
  end

  defp summarize(fields) do
    [
      Map.get(fields, "format_name"),
      format_duration(Map.get(fields, "duration")),
      fields |> Map.get("codec_name", []) |> List.first()
    ]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join(", ")
  end

  defp format_duration(nil), do: nil

  defp format_duration(raw) do
    case Float.parse(raw) do
      {seconds, _} when seconds > 0 ->
        total = trunc(seconds)
        "#{div(total, 60)}:#{String.pad_leading("#{rem(total, 60)}", 2, "0")}"

      _ ->
        nil
    end
  end

  defp first_line(output) do
    output
    |> String.split("\n", trim: true)
    |> List.first()
    |> Kernel.||("unreadable")
    |> String.slice(0, 200)
  end

  defp verdict(status, detail), do: %{"status" => status, "detail" => detail}
end
