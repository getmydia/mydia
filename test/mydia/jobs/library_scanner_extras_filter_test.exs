defmodule Mydia.Jobs.LibraryScannerExtrasFilterTest do
  @moduledoc """
  Tests the `SampleDetector` composition that classifies extras, samples, and
  trailers found during a scan.

  The scanner itself no longer filters these out of what it processes --
  since Task 5, every unrecognized path (extras included) becomes an
  `ImportCandidate` when the library has `auto_import: true`, classified via
  `parsed_info["is_sample"/"is_trailer"/"is_extra"]` (see
  `library_scanner_extras_test.exs` for the end-to-end behavior and
  `library_scanner_ingest_test.exs` for the review-only promotion rule this
  classification drives). This module instead pins the lower-level
  composition -- `SampleDetector.skip_detection?/1` plus
  `SampleDetector.excluded?(SampleDetector.detect/1)` -- that
  `Mydia.Library.ReleaseParser.parse_with_path/1` runs internally
  (`SampleDetector.apply_detection/2`) to populate those flags.
  """
  use ExUnit.Case, async: true

  alias Mydia.Library.SampleDetector

  # Mirrors the file_info structure used by the library scanner
  defp file_info(path) do
    %{
      path: path,
      size: 1_000_000,
      mtime: ~N[2024-01-01 00:00:00]
    }
  end

  # Replicates the split_with logic from LibraryScanner.process_scan_result
  defp split_extras(files) do
    Enum.split_with(files, fn file_info ->
      SampleDetector.skip_detection?(file_info.path) or
        not SampleDetector.excluded?(SampleDetector.detect(file_info.path))
    end)
  end

  describe "filtering extras from scan results" do
    test "passes through regular files" do
      files = [
        file_info("/media/movies/Avatar (2009)/Avatar.2009.1080p.mkv"),
        file_info("/media/movies/Inception (2010)/Inception.2010.BluRay.mkv")
      ]

      {regular, extras} = split_extras(files)

      assert length(regular) == 2
      assert extras == []
    end

    test "filters files in Sample folder" do
      files = [
        file_info("/media/movies/Avatar (2009)/Avatar.2009.1080p.mkv"),
        file_info("/media/movies/Avatar (2009)/Sample/avatar-sample.mkv")
      ]

      {regular, extras} = split_extras(files)

      assert length(regular) == 1
      assert length(extras) == 1
      assert hd(regular).path =~ "Avatar.2009.1080p.mkv"
      assert hd(extras).path =~ "Sample/"
    end

    test "filters files in Featurettes folder" do
      files = [
        file_info("/media/movies/Movie/Movie.mkv"),
        file_info("/media/movies/Movie/Featurettes/making-of.mkv")
      ]

      {regular, extras} = split_extras(files)

      assert length(regular) == 1
      assert length(extras) == 1
    end

    test "filters files in Trailers folder" do
      files = [
        file_info("/media/movies/Movie/Movie.mkv"),
        file_info("/media/movies/Movie/Trailers/trailer.mkv")
      ]

      {regular, extras} = split_extras(files)

      assert length(regular) == 1
      assert length(extras) == 1
    end

    test "filters files in Deleted Scenes folder" do
      files = [
        file_info("/media/movies/Movie/Movie.mkv"),
        file_info("/media/movies/Movie/Deleted Scenes/scene1.mkv")
      ]

      {regular, extras} = split_extras(files)

      assert length(regular) == 1
      assert length(extras) == 1
    end

    test "filters files in Interviews folder" do
      files = [
        file_info("/media/movies/Movie/Movie.mkv"),
        file_info("/media/movies/Movie/Interviews/director.mkv")
      ]

      {regular, extras} = split_extras(files)

      assert length(regular) == 1
      assert length(extras) == 1
    end

    test "filters files with -sample filename suffix" do
      files = [
        file_info("/media/movies/Movie/Movie.mkv"),
        file_info("/media/movies/Movie/Movie-sample.mkv")
      ]

      {regular, extras} = split_extras(files)

      assert length(regular) == 1
      assert length(extras) == 1
    end

    test "filters files with -trailer filename suffix" do
      files = [
        file_info("/media/movies/Movie/Movie.mkv"),
        file_info("/media/movies/Movie/Movie-trailer.mkv")
      ]

      {regular, extras} = split_extras(files)

      assert length(regular) == 1
      assert length(extras) == 1
    end

    test "preserves .strm files in Sample folders (skip_detection)" do
      files = [
        file_info("/media/movies/Movie/Sample/stream.strm")
      ]

      {regular, extras} = split_extras(files)

      assert length(regular) == 1
      assert extras == []
    end

    test "handles mixed regular and extras from a typical BluRay rip" do
      files = [
        file_info("/media/movies/Movie.2024.BluRay/Movie.2024.BluRay.mkv"),
        file_info("/media/movies/Movie.2024.BluRay/Sample/sample.mkv"),
        file_info("/media/movies/Movie.2024.BluRay/Featurettes/making-of.mkv"),
        file_info("/media/movies/Movie.2024.BluRay/Featurettes/cast-interviews.mkv"),
        file_info("/media/movies/Movie.2024.BluRay/Trailers/trailer1.mkv"),
        file_info("/media/movies/Movie.2024.BluRay/Behind The Scenes/bts.mkv"),
        file_info("/media/movies/Movie.2024.BluRay/Extras/bonus.mkv")
      ]

      {regular, extras} = split_extras(files)

      assert length(regular) == 1
      assert length(extras) == 6
      assert hd(regular).path =~ "Movie.2024.BluRay.mkv"
    end

    test "folder detection is case-insensitive" do
      files = [
        file_info("/media/movies/Movie/SAMPLE/test.mkv"),
        file_info("/media/movies/Movie/TRAILERS/trailer.mkv"),
        file_info("/media/movies/Movie/EXTRAS/bonus.mkv")
      ]

      {regular, extras} = split_extras(files)

      assert regular == []
      assert length(extras) == 3
    end
  end
end
