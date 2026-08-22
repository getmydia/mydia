defmodule Mydia.Subtitles.Format do
  @moduledoc """
  Converts subtitle content between text formats.

  SRT and VTT transcode in pure Elixir, which covers the overwhelming majority
  of sidecar files with no process spawn. Anything else falls through to ffmpeg
  inside this module, so callers never branch on format.

  Image formats (PGS, VobSub) are bitmaps and cannot become text. They are
  rejected rather than silently mangled.
  """

  @image_formats ~w(pgs vobsub dvd_subtitle hdmv_pgs_subtitle)

  # A provider states a format in its search results, but SubDL and the relay
  # both hardcode "srt" there because the real extension is only visible once
  # the archive is opened, one request later. The bytes are the only honest
  # source, so the declared format is treated as a hint and this is the answer.
  @srt_cue ~r/^\d+\s*\n\d{2}:\d{2}:\d{2},\d{3}\s*-->/m
  @microdvd ~r/^\{\d+\}\{\d+\}/m
  @probe_bytes 4096

  @doc """
  Returns true when the format carries bitmaps rather than text.
  """
  @spec image_format?(String.t()) :: boolean()
  def image_format?(format), do: format in @image_formats

  @doc """
  Reads the subtitle format out of the content itself.

  Returns one of `Subtitle.supported_formats/0`. `.ssa` reports as `"ass"`: it
  shares the `[Script Info]` header and ffmpeg treats the two identically.

  Only the first #{@probe_bytes} bytes are examined, which bounds the work on a
  large file and is far past any header. The regexes carry no `/u` modifier, so
  they match byte by byte and a Latin-1 file is read correctly.
  """
  @spec detect(binary()) ::
          {:ok, String.t()}
          | {:error, {:unsupported_subtitle_format, String.t()} | :unrecognized_subtitle_content}
  def detect(content) when is_binary(content) do
    head = content |> strip_bom() |> binary_slice(0, @probe_bytes)

    cond do
      ass?(head) -> {:ok, "ass"}
      String.starts_with?(head, "WEBVTT") -> {:ok, "vtt"}
      Regex.match?(@srt_cue, head) -> {:ok, "srt"}
      Regex.match?(@microdvd, head) -> {:error, {:unsupported_subtitle_format, "sub"}}
      true -> {:error, :unrecognized_subtitle_content}
    end
  end

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

  defp ass?(head) do
    String.contains?(head, "[Script Info]") or
      String.contains?(head, "[V4+ Styles]") or
      String.contains?(head, "[V4 Styles]")
  end

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
    |> Enum.map_join("\n", fn line ->
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

      # System.cmd/3 has no :timeout option and raises ArgumentError on unknown
      # options, so a timeout cannot be passed here.
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
