defmodule Mydia.Library.FileRanking do
  @moduledoc """
  Ranks media files by playback quality.

  Used wherever a caller names a movie or an episode rather than a specific
  file, so the server has to choose one. Those call sites previously took the
  head of an unordered `has_many` preload, which meant the file that played was
  whichever row the database happened to return first.

  Ranking is deliberately device-blind: it always prefers the highest-quality
  file, because the server cannot know what the requesting client can handle.
  Clients that care which file plays send an explicit file id instead, which
  skips this module entirely.
  """

  alias Mydia.Library.MediaFile

  # Keys are lowercased; values are vertical pixels. Covers everything
  # `Mydia.Library.FileAnalyzer.extract_resolution/1` (file_analyzer.ex:318)
  # emits, plus the extra spellings `Mydia.Library.ReleaseParser` can persist
  # (release_parser.ex:243).
  @named_resolutions %{
    "8k" => 4320,
    "4320p" => 4320,
    "4k" => 2160,
    "uhd" => 2160,
    "2160p" => 2160,
    "2k" => 1440,
    "qhd" => 1440,
    "1440p" => 1440,
    "fhd" => 1080,
    "1080p" => 1080,
    "hd" => 720,
    "720p" => 720,
    "576p" => 576,
    "540p" => 540,
    "sd" => 480,
    "480p" => 480,
    "360p" => 360
  }

  # Deliberately unanchored at the start. Originally matched the player's
  # `MediaFileSelector.parseToPixels` (media_file_selector.dart:46) for odd
  # values like "1920x1080" -> 1080. Additionally accepts interlaced suffixes
  # because ReleaseParser persists them (e.g. "1080i") and the Dart parser
  # does not yet handle them. Treats interlaced as equal to progressive at
  # the same height.
  @numeric_resolution ~r/(\d+)[pi]?$/

  @doc """
  Parses a resolution string into a vertical pixel count.

  Returns `0` for `nil` and for anything unparseable, which sorts those files
  last. A `nil` resolution means the file has not been analyzed yet, and an
  unanalyzed file is the least safe thing to pick blindly.
  """
  @spec resolution_pixels(String.t() | nil) :: non_neg_integer()
  def resolution_pixels(nil), do: 0

  def resolution_pixels(resolution) when is_binary(resolution) do
    key = resolution |> String.trim() |> String.downcase()

    case Map.fetch(@named_resolutions, key) do
      {:ok, pixels} -> pixels
      :error -> parse_numeric_resolution(key)
    end
  end

  def resolution_pixels(_other), do: 0

  @doc """
  Returns the highest-quality file in `files`, or `nil` when `files` is empty.

  Callers use the `nil` to detect "this media item has no playable files".
  """
  @spec best([MediaFile.t()]) :: MediaFile.t() | nil
  def best([]), do: nil
  def best([file]), do: file
  def best(files) when is_list(files), do: files |> sort() |> hd()

  @doc """
  Sorts `files` best-first.

  Resolution descending, then bitrate descending, then id descending. The id is
  an arbitrary but stable final tiebreak: two files equal on every quality
  signal are interchangeable, but ranking them consistently means the same set
  produces the same answer on every call, whatever order the database returned.
  """
  @spec sort([MediaFile.t()]) :: [MediaFile.t()]
  def sort(files) when is_list(files) do
    Enum.sort_by(files, &rank_key/1, :desc)
  end

  defp rank_key(%MediaFile{} = file) do
    {resolution_pixels(file.resolution), file.bitrate || 0, file.id}
  end

  defp parse_numeric_resolution(key) do
    case Regex.run(@numeric_resolution, key) do
      [_full, digits] -> String.to_integer(digits)
      nil -> 0
    end
  end
end
