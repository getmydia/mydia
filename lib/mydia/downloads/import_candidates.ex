defmodule Mydia.Downloads.ImportCandidates do
  @moduledoc """
  Builds the file listing that a failed import stores on its download, so the
  operator can see what the download actually contained and match files by hand.

  A candidate records why the automatic importer skipped a file. For files
  rejected on extension alone, it also carries an ffprobe verdict, which is what
  separates an obfuscated release from a fake one.
  """

  alias Mydia.Library.ContentProbe
  alias Mydia.Library.ReleaseParser
  alias Mydia.Library.SampleDetector

  @video_extensions ~w(.mkv .mp4 .avi .mov .wmv .flv .webm .m4v .mpg .mpeg .m2ts)
  @music_extensions ~w(.mp3 .flac .wav .aac .ogg .m4a .wma .opus .ape .alac .aiff)
  @book_extensions ~w(.epub .pdf .mobi .azw .azw3 .cbr .cbz .djvu .fb2 .lit .txt .rtf)
  @adult_extensions ~w(.mkv .mp4 .avi .mov .wmv .flv .webm .m4v .jpg .jpeg .png .gif .webp .bmp .tiff)

  @probe_size_floor 10_485_760
  @probe_cap 20

  @doc "Minimum file size, in bytes, before an extension-rejected file is probed."
  @spec probe_size_floor() :: pos_integer()
  def probe_size_floor, do: @probe_size_floor

  @doc "Maximum number of files probed per download."
  @spec probe_cap() :: pos_integer()
  def probe_cap, do: @probe_cap

  @doc """
  Turns the importer's file list into persistable candidates.

  `library_type` is the resolved library's type, matching the branches in
  `MediaImport.filter_files_for_library_type/2`. `parser_opts` is the same
  keyword list the importer passes to `ReleaseParser.parse/2`, so the season and
  episode guesses here match the ones the importer would have made.
  """
  @spec build([map()], atom(), keyword()) :: [map()]
  def build(files, library_type, parser_opts) when is_list(files) do
    files
    |> Enum.map(&candidate(&1, library_type, parser_opts))
    |> add_probes()
  end

  defp candidate(file, library_type, parser_opts) do
    parsed = ReleaseParser.parse(file.name, parser_opts)

    %{
      "path" => file.path,
      "name" => file.name,
      "size" => file.size,
      "skip_reason" => skip_reason(file, library_type),
      "parsed_season" => parsed && parsed.season,
      "parsed_episode" => parsed && first_episode(parsed)
    }
  end

  defp first_episode(%{episodes: episodes}) when is_list(episodes), do: List.first(episodes)
  defp first_episode(_parsed), do: nil

  # Mirrors the importer's two filters in the same order, so the reason shown to
  # the operator is the reason the file was actually dropped.
  defp skip_reason(file, library_type) do
    cond do
      not importable?(file, library_type) ->
        "not_video_extension"

      SampleDetector.skip_detection?(file.path) ->
        nil

      true ->
        detection = SampleDetector.detect(file.path)

        if SampleDetector.excluded?(detection) do
          SampleDetector.exclusion_reason(detection)
        end
    end
  end

  @doc """
  True when `file` has an extension the given library type accepts.

  This module owns the extension vocabulary. `MediaImport` delegates its own
  filtering here so the skip reason shown to the operator can never disagree
  with the filter that actually dropped the file.
  """
  @spec importable?(map(), atom()) :: boolean()
  def importable?(file, library_type) do
    ext = file.name |> Path.extname() |> String.downcase()

    case library_type do
      type when type in [:movies, :series, :mixed] -> ext in @video_extensions
      :music -> ext in @music_extensions
      :books -> ext in @book_extensions
      :adult -> ext in @adult_extensions
      _unknown -> true
    end
  end

  # Only files rejected purely on extension are worth probing: everything else
  # either imported fine or was correctly identified as a sample.
  defp add_probes(candidates) do
    probable =
      candidates
      |> Enum.filter(&probe?/1)
      |> Enum.take(@probe_cap)
      |> MapSet.new(& &1["path"])

    Enum.map(candidates, fn candidate ->
      if MapSet.member?(probable, candidate["path"]) do
        Map.put(candidate, "probe", ContentProbe.probe(candidate["path"]))
      else
        candidate
      end
    end)
  end

  defp probe?(candidate) do
    candidate["skip_reason"] == "not_video_extension" and
      candidate["size"] >= @probe_size_floor
  end
end
