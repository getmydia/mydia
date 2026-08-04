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
         true <- File.regular?(path) || {:error, :not_a_file} do
      run(ffprobe, path)
    else
      {:error, :ffprobe_not_found} -> verdict("unknown", "ffprobe not installed")
      {:error, :not_a_file} -> verdict("unknown", "file not found")
      false -> verdict("unknown", "file not found")
    end
  end

  defp executable do
    case System.find_executable("ffprobe") do
      nil -> {:error, :ffprobe_not_found}
      path -> {:ok, path}
    end
  end

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

    task = Task.async(fn -> System.cmd(ffprobe, args, stderr_to_stdout: true) end)

    case Task.yield(task, @timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} -> classify(output)
      {:ok, {output, _code}} -> verdict("not_media", first_line(output))
      nil -> verdict("unknown", "probe timed out")
    end
  rescue
    exception ->
      Logger.debug("Content probe raised: #{Exception.message(exception)}")
      verdict("unknown", "probe failed")
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
