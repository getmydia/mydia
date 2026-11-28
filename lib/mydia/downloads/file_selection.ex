defmodule Mydia.Downloads.FileSelection do
  @moduledoc """
  Decides which files of a torrent are worth downloading.

  A file is kept when the importer would take it (a video extension that is
  not a sample, trailer or extra) or when it is a subtitle. When nothing in
  the torrent qualifies, every file is kept, so an unusual release is never
  reduced to an empty download.

  Pure functions only; the download client applies the result.
  """

  alias Mydia.Downloads.ImportCandidates
  alias Mydia.Downloads.Structs.TorrentFile
  alias Mydia.Library.SampleDetector

  @subtitle_extensions ~w(.srt .ass .ssa .sub .idx .sup .vtt)

  @doc """
  True when the importer would take the file at `path`. Same filters in the
  same order as `ImportCandidates`: the extension first, then sample
  detection, which the importer skips for some types (`.m2ts`, `.flv`).
  """
  @spec importable?(String.t()) :: boolean()
  def importable?(""), do: false

  def importable?(path) when is_binary(path) do
    ImportCandidates.importable?(%{name: Path.basename(path)}, :series) and
      (SampleDetector.skip_detection?(path) or
         not SampleDetector.excluded?(SampleDetector.detect(path)))
  end

  @doc "True when `path` has a subtitle extension, ignoring case."
  @spec subtitle?(String.t()) :: boolean()
  def subtitle?(path) when is_binary(path) do
    path |> Path.extname() |> String.downcase() |> then(&(&1 in @subtitle_extensions))
  end

  @doc """
  True when at least one of the files at `indexes` is a video the importer
  would take. Only `index` and `path` are read, so listings and `TorrentFile`
  structs both work.
  """
  @spec keeps_video?([%{index: non_neg_integer(), path: String.t()}], [non_neg_integer()]) ::
          boolean()
  def keeps_video?(files, indexes) when is_list(files) and is_list(indexes) do
    chosen = MapSet.new(indexes)
    Enum.any?(files, &(&1.index in chosen and importable?(&1.path)))
  end

  @doc """
  Returns the sorted indices of the files to download.

  Falls back to every index when no file is importable or a subtitle.
  """
  @spec keep([TorrentFile.t()]) :: [non_neg_integer()]
  def keep(files) when is_list(files) do
    kept =
      for %TorrentFile{index: index, path: path} <- files,
          importable?(path) or subtitle?(path),
          do: index

    case kept do
      [] -> files |> Enum.map(& &1.index) |> Enum.sort()
      kept -> Enum.sort(kept)
    end
  end
end
