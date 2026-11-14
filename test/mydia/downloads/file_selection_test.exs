defmodule Mydia.Downloads.FileSelectionTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.FileSelection
  alias Mydia.Downloads.Structs.TorrentFile

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  defp to_files(paths) do
    paths
    |> Enum.with_index()
    |> Enum.map(fn {path, i} -> %TorrentFile{index: i, path: path, size: 1_000} end)
  end

  defp index_of(paths, path), do: Enum.find_index(paths, &(&1 == path))

  test "season pack keeps every episode and subtitle, skips samples and junk" do
    files =
      for(n <- 1..24, do: "Glass Harbor S02/Glass.Harbor.S02E#{pad(n)}.mkv") ++
        [
          "Glass Harbor S02/Sample/sample.mkv",
          "Glass Harbor S02/Glass.Harbor.S02E01.en.srt",
          "Glass Harbor S02/release.nfo",
          "Glass Harbor S02/cover.jpg"
        ]

    kept = FileSelection.keep(to_files(files))

    assert length(kept) == 25
    assert kept == Enum.sort(kept)
    refute index_of(files, "Glass Harbor S02/Sample/sample.mkv") in kept
    refute index_of(files, "Glass Harbor S02/release.nfo") in kept
    refute index_of(files, "Glass Harbor S02/cover.jpg") in kept
    assert index_of(files, "Glass Harbor S02/Glass.Harbor.S02E01.en.srt") in kept
  end

  test "trailer and .exe are skipped" do
    files = [
      "Glass Harbor/Glass.Harbor.2020.mkv",
      "Glass Harbor/Glass.Harbor-trailer.mkv",
      "Glass Harbor/Trailers/teaser.mkv",
      "Glass Harbor/setup.exe"
    ]

    assert FileSelection.keep(to_files(files)) == [0]
    refute FileSelection.importable?("Glass Harbor/Glass.Harbor-trailer.mkv")
    refute FileSelection.importable?("Glass Harbor/setup.exe")
  end

  test "subtitle detection is case-insensitive" do
    for ext <- ~w(.SRT .Idx .ass .ssa .sub .sup .vtt) do
      assert FileSelection.subtitle?("Glass Harbor/movie#{ext}")
    end

    refute FileSelection.subtitle?("Glass Harbor/movie.nfo")
    refute FileSelection.subtitle?("")
    refute FileSelection.importable?("")
  end

  test "all-junk torrent keeps every index" do
    assert FileSelection.keep(to_files(["setup.exe", "readme.txt"])) == [0, 1]
  end

  test "empty torrent keeps nothing" do
    assert FileSelection.keep([]) == []
  end
end
