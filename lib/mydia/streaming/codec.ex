defmodule Mydia.Streaming.Codec do
  @moduledoc """
  Centralized codec normalization and detection utilities.

  This module provides functions to normalize video and audio codec names
  from various formats (FFprobe output, filename parsing, etc.) into
  canonical forms used for streaming compatibility checks.
  """

  @doc """
  Normalizes a video codec name to its canonical form.

  Handles various naming conventions from FFprobe, filenames, and other sources.

  ## Examples

      iex> normalize_video_codec("H.264 (High)")
      "h264"

      iex> normalize_video_codec("hevc")
      "hevc"

      iex> normalize_video_codec("x265")
      "hevc"

      iex> normalize_video_codec(nil)
      nil
  """
  @spec normalize_video_codec(String.t() | nil) :: String.t() | nil
  def normalize_video_codec(nil), do: nil

  def normalize_video_codec(codec) when is_binary(codec) do
    find_matching_codec(codec, video_codec_patterns()) || String.downcase(codec)
  end

  @doc """
  Normalizes an audio codec name to its canonical form.

  Handles various naming conventions from FFprobe, filenames, and other sources.

  ## Examples

      iex> normalize_audio_codec("AAC (LC)")
      "aac"

      iex> normalize_audio_codec("DTS-HD MA")
      "dts-hd"

      iex> normalize_audio_codec("ac3")
      "ac3"

      iex> normalize_audio_codec(nil)
      nil
  """
  @spec normalize_audio_codec(String.t() | nil) :: String.t() | nil
  def normalize_audio_codec(nil), do: nil

  def normalize_audio_codec(codec) when is_binary(codec) do
    find_matching_codec(codec, audio_codec_patterns()) || String.downcase(codec)
  end

  @doc """
  Checks if a video codec is browser-compatible for direct playback.

  ## Examples

      iex> browser_compatible_video?("h264")
      true

      iex> browser_compatible_video?("hevc")
      false
  """
  @spec browser_compatible_video?(String.t() | nil) :: boolean()
  def browser_compatible_video?(nil), do: false

  def browser_compatible_video?(codec) do
    normalize_video_codec(codec) in ["h264", "vp9", "vp8", "av1", "theora"]
  end

  @doc """
  Checks if an audio codec is browser-compatible for direct playback.

  ## Examples

      iex> browser_compatible_audio?("aac")
      true

      iex> browser_compatible_audio?("dts")
      false
  """
  @spec browser_compatible_audio?(String.t() | nil) :: boolean()
  def browser_compatible_audio?(nil), do: false

  def browser_compatible_audio?(codec) do
    normalize_audio_codec(codec) in ["aac", "mp3", "opus", "vorbis", "flac", "pcm"]
  end

  # Video codec patterns - order matters, more specific patterns first
  defp video_codec_patterns do
    [
      {~r/\b(?:hevc|h\.?265|x\.?265)\b/i, "hevc"},
      {~r/\b(?:h\.?264|x\.?264|avc1?)\b/i, "h264"},
      {~r/\bvp0?9\b/i, "vp9"},
      {~r/\bav0?1\b/i, "av1"},
      {~r/\b(?:mpeg-?4|xvid|divx)\b/i, "mpeg4"},
      {~r/\bwmv[23]?\b/i, "wmv3"},
      {~r/\bvp0?8\b/i, "vp8"},
      {~r/\bmpeg-?2\b/i, "mpeg2"},
      {~r/\bvc-?1\b/i, "vc1"},
      {~r/\btheora\b/i, "theora"}
    ]
  end

  # Audio codec patterns - order matters, more specific patterns first
  defp audio_codec_patterns do
    [
      {~r/\b(?:truehd|mlp)\b/i, "truehd"},
      {~r/\bdts[- ]?(?:hd|ma|x|hdma)\b/i, "dts-hd"},
      {~r/\bdts\b/i, "dts"},
      # E-AC3 before AC3: the analyzer labels E-AC3 "DD+", and the AC3
      # pattern's `\bdd` matches the "DD" in front of the "+".
      {~r/(?:\be-?ac-?3\b|\bddp|\bdd\+|\bdolby\s*digital\s*plus\b)/i, "eac3"},
      {~r/\b(?:ac-?3|dolby\s*digital|dd5?\.?1?)\b/i, "ac3"},
      {~r/\baac\b/i, "aac"},
      {~r/\bmp3\b/i, "mp3"},
      {~r/\bopus\b/i, "opus"},
      {~r/\bvorbis\b/i, "vorbis"},
      {~r/\bflac\b/i, "flac"},
      {~r/\bpcm\b/i, "pcm"},
      {~r/\balac\b/i, "alac"},
      {~r/\bwma\b/i, "wma"}
    ]
  end

  # Finds the first matching pattern and returns the canonical codec name
  defp find_matching_codec(codec, patterns) do
    Enum.find_value(patterns, fn {pattern, canonical} ->
      if Regex.match?(pattern, codec), do: canonical
    end)
  end
end
