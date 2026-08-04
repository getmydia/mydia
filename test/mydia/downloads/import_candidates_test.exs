defmodule Mydia.Downloads.ImportCandidatesTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.ImportCandidates

  @moduletag :tmp_dir

  defp file(tmp_dir, name, size) do
    path = Path.join(tmp_dir, name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, :binary.copy(<<0>>, size))
    %{path: path, name: name, size: size}
  end

  test "flags a non-video extension and probes it", %{tmp_dir: tmp_dir} do
    big = ImportCandidates.probe_size_floor() + 1
    files = [file(tmp_dir, "payload.exe", big)]

    assert [candidate] = ImportCandidates.build(files, :series, [])
    assert candidate["name"] == "payload.exe"
    assert candidate["size"] == big
    assert candidate["skip_reason"] == "not_video_extension"
    assert candidate["probe"]["status"] in ["not_media", "unknown"]
  end

  test "does not probe extension-rejected files below the size floor", %{tmp_dir: tmp_dir} do
    files = [file(tmp_dir, "release.nfo", 2048)]

    assert [candidate] = ImportCandidates.build(files, :series, [])
    assert candidate["skip_reason"] == "not_video_extension"
    refute Map.has_key?(candidate, "probe")
  end

  test "flags a sample with the detector's reason and does not probe it", %{tmp_dir: tmp_dir} do
    files = [file(tmp_dir, "show.s01e01-sample.mkv", 1024)]

    assert [candidate] = ImportCandidates.build(files, :series, [])
    assert candidate["skip_reason"] =~ "Sample"
    refute Map.has_key?(candidate, "probe")
  end

  test "leaves an importable file unflagged and records the parser guess", %{tmp_dir: tmp_dir} do
    files = [file(tmp_dir, "Some.Show.S03E06.1080p.WEB-DL.mkv", 1024)]

    assert [candidate] = ImportCandidates.build(files, :series, [])
    assert candidate["skip_reason"] == nil
    assert candidate["parsed_season"] == 3
    assert candidate["parsed_episode"] == 6
    refute Map.has_key?(candidate, "probe")
  end

  test "probes at most probe_cap files", %{tmp_dir: tmp_dir} do
    big = ImportCandidates.probe_size_floor() + 1

    files =
      for i <- 1..(ImportCandidates.probe_cap() + 3) do
        file(tmp_dir, "payload#{i}.exe", big)
      end

    candidates = ImportCandidates.build(files, :series, [])

    probed = Enum.count(candidates, &Map.has_key?(&1, "probe"))
    assert probed == ImportCandidates.probe_cap()
  end
end
