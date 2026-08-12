defmodule Mydia.Subtitles.Format do
  @moduledoc """
  Converts subtitle content between text formats.

  SRT and VTT transcode in pure Elixir, which covers the overwhelming majority
  of sidecar files with no process spawn. Anything else falls through to ffmpeg
  inside this module, so callers never branch on format.

  Image formats (PGS, VobSub) are bitmaps and cannot become text. They are
  rejected rather than silently mangled.
  """

  require Logger

  @image_formats ~w(pgs vobsub dvd_subtitle hdmv_pgs_subtitle)

  @doc """
  Returns true when the format carries bitmaps rather than text.
  """
  @spec image_format?(String.t()) :: boolean()
  def image_format?(format), do: format in @image_formats

  @doc """
  Converts subtitle content from one format to another.
  """
  @spec convert(binary(), String.t(), String.t()) ::
          {:ok, binary()}
          | {:error, :image_subtitle | {:ffmpeg_failed, String.t()} | :ffmpeg_not_found}
  def convert(content, from, to)

  def convert(_content, from, _to) when from in @image_formats, do: {:error, :image_subtitle}
  def convert(_content, _from, to) when to in @image_formats, do: {:error, :image_subtitle}
  def convert(content, same, same), do: {:ok, normalize(content)}
  def convert(content, "srt", "vtt"), do: {:ok, srt_to_vtt(content)}
  def convert(content, "vtt", "srt"), do: {:ok, vtt_to_srt(content)}
  def convert(content, from, to), do: ffmpeg_convert(content, from, to)

  ## Private

  defp normalize(content) do
    content
    |> strip_bom()
    |> String.replace("\r\n", "\n")
  end

  defp strip_bom("﻿" <> rest), do: rest
  defp strip_bom(content), do: content

  defp srt_to_vtt(content) do
    body =
      content
      |> normalize()
      |> String.replace(~r/(\d{2}:\d{2}:\d{2}),(\d{3})/, "\\1.\\2")
      |> String.trim_leading()

    "WEBVTT\n\n" <> body
  end

  defp vtt_to_srt(content) do
    content
    |> normalize()
    |> String.split(~r/\n{2,}/, trim: true)
    |> Enum.reject(&metadata_block?/1)
    |> Enum.map(&strip_cue_identifier/1)
    |> Enum.with_index(1)
    |> Enum.map_join("\n\n", fn {cue, index} ->
      "#{index}\n" <> rewrite_timing_line(cue)
    end)
    |> Kernel.<>("\n")
  end

  # The timing line is the only line where a VTT timestamp appears, so scope
  # the rewrite to it: cue text may otherwise contain a timestamp-shaped
  # substring that would get mangled by accident. WebVTT also makes the hours
  # segment optional (MM:SS.mmm is valid), while SRT always requires it, so a
  # missing hours group defaults to "00" rather than passing the timestamp
  # through unconverted.
  defp rewrite_timing_line(cue) do
    cue
    |> String.split("\n")
    |> Enum.map(fn line ->
      if String.contains?(line, "-->") do
        Regex.replace(~r/(?:(\d{2}):)?(\d{2}:\d{2})\.(\d{3})/, line, fn _match,
                                                                        hours,
                                                                        rest,
                                                                        millis ->
          hours = if hours == "", do: "00", else: hours
          "#{hours}:#{rest},#{millis}"
        end)
      else
        line
      end
    end)
    |> Enum.join("\n")
  end

  # WEBVTT header, NOTE comments and STYLE/REGION blocks carry no cue.
  defp metadata_block?(block) do
    trimmed = String.trim_leading(block)

    String.starts_with?(trimmed, "WEBVTT") or
      String.starts_with?(trimmed, "NOTE") or
      String.starts_with?(trimmed, "STYLE") or
      String.starts_with?(trimmed, "REGION") or
      not String.contains?(block, "-->")
  end

  # A VTT cue may carry an identifier line before its timing line. SRT numbers
  # cues itself, so drop anything above the arrow.
  defp strip_cue_identifier(cue) do
    lines = String.split(cue, "\n")
    index = Enum.find_index(lines, &String.contains?(&1, "-->")) || 0

    lines
    |> Enum.drop(index)
    |> Enum.join("\n")
  end

  defp ffmpeg_convert(content, from, to) do
    id = :erlang.unique_integer([:positive])
    input = Path.join(System.tmp_dir!(), "mydia-subconv-#{id}.#{from}")
    output = Path.join(System.tmp_dir!(), "mydia-subconv-#{id}.#{to}")

    try do
      File.write!(input, content)

      case System.cmd("ffmpeg", ["-v", "error", "-y", "-i", input, output],
             stderr_to_stdout: true
           ) do
        {_out, 0} -> {:ok, File.read!(output)}
        {out, _code} -> {:error, {:ffmpeg_failed, String.slice(out, 0, 500)}}
      end
    rescue
      _e in ErlangError -> {:error, :ffmpeg_not_found}
    after
      File.rm(input)
      File.rm(output)
    end
  end
end
