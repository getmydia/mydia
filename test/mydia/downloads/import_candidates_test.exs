defmodule Mydia.Downloads.ImportCandidatesTest do
  use Mydia.DataCase, async: true

  import Mydia.DownloadsFixtures
  import Mydia.SettingsFixtures

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

  describe "load/1" do
    test "returns the live listing when the folder is readable", %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "live")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "extra.mkv"), "x")

      # A resolvable client whose download_directory is provably NOT `dir`
      # is required here: `shared_download_root?/2` now fails closed, so
      # without a client that positively rules out `dir` as the shared
      # root, this would fall back to the snapshot instead of listing live.
      client = client_with_unrelated_root(tmp_dir)

      download =
        download_fixture(%{
          download_client: client.name,
          metadata: %{
            "save_path" => dir,
            "import_candidates" => [
              %{"path" => Path.join(dir, "old.exe"), "name" => "old.exe", "size" => 1}
            ]
          }
        })

      assert {:ok, :live, [candidate]} = ImportCandidates.load(download)
      assert candidate["name"] == "extra.mkv"
      assert candidate["missing"] == false
    end

    test "falls back to the snapshot when the folder is gone", %{tmp_dir: tmp_dir} do
      client = client_with_unrelated_root(tmp_dir)

      download =
        download_fixture(%{
          download_client: client.name,
          metadata: %{
            "save_path" => Path.join(tmp_dir, "gone"),
            "import_candidates" => [
              %{
                "path" => Path.join(tmp_dir, "gone/payload.exe"),
                "name" => "payload.exe",
                "size" => 1,
                "skip_reason" => "not_video_extension"
              }
            ]
          }
        })

      assert {:ok, :snapshot, [candidate]} = ImportCandidates.load(download)
      assert candidate["name"] == "payload.exe"
      assert candidate["missing"] == true
    end

    test "errors when there is neither a listing nor a snapshot" do
      download = download_fixture(%{metadata: %{}})

      assert {:error, :unavailable} = ImportCandidates.load(download)
    end

    test "falls back to the snapshot when there is no explicit save_path", %{tmp_dir: tmp_dir} do
      # No "save_path" key at all: the old behaviour derived a directory to
      # list from `Path.dirname/1` of the first snapshot path. That is the
      # hazard this task fixes, so with no explicit save_path there must be
      # no re-listing at all, live or otherwise.
      dir = Path.join(tmp_dir, "implicit")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "payload.exe"), "x")
      File.write!(Path.join(dir, "unrelated.mkv"), "y")

      download =
        download_fixture(%{
          metadata: %{
            "import_candidates" => [
              %{"path" => Path.join(dir, "payload.exe"), "name" => "payload.exe", "size" => 1}
            ]
          }
        })

      assert {:ok, :snapshot, [candidate]} = ImportCandidates.load(download)
      assert candidate["name"] == "payload.exe"
      assert candidate["missing"] == false
    end

    test "does not enumerate the client's shared download root", %{tmp_dir: tmp_dir} do
      root = Path.join(tmp_dir, "shared")
      File.mkdir_p!(root)
      File.write!(Path.join(root, "Some.Other.Show.S01E01.mkv"), "unrelated")
      File.write!(Path.join(root, "Silo.S01E01.mkv"), "silo")

      client = download_client_config_fixture(%{download_directory: root})

      download =
        download_fixture(%{
          download_client: client.name,
          metadata: %{
            "save_path" => root,
            "import_candidates" => [
              %{
                "path" => Path.join(root, "Silo.S01E01.mkv"),
                "name" => "Silo.S01E01.mkv",
                "size" => 4
              }
            ]
          }
        })

      # A live listing here would have surfaced both files. Getting the
      # snapshot back with only the recorded candidate proves the shared
      # root was never walked.
      assert {:ok, :snapshot, [candidate]} = ImportCandidates.load(download)
      assert candidate["name"] == "Silo.S01E01.mkv"
      assert candidate["missing"] == false
    end

    test "still re-lists a save_path that is a per-download subfolder of the shared root",
         %{tmp_dir: tmp_dir} do
      root = Path.join(tmp_dir, "shared")
      own_dir = Path.join(root, "Silo.S01E01.1080p-GROUP")
      File.mkdir_p!(own_dir)
      File.write!(Path.join(own_dir, "Silo.S01E01.mkv"), "silo")
      File.write!(Path.join(root, "Some.Other.Show.S01E01.mkv"), "unrelated")

      client = download_client_config_fixture(%{download_directory: root})

      download =
        download_fixture(%{
          download_client: client.name,
          metadata: %{
            "save_path" => own_dir,
            "import_candidates" => [
              %{
                "path" => Path.join(own_dir, "Silo.S01E01.mkv"),
                "name" => "Silo.S01E01.mkv",
                "size" => 4
              }
            ]
          }
        })

      assert {:ok, :live, [candidate]} = ImportCandidates.load(download)
      assert candidate["name"] == "Silo.S01E01.mkv"
    end

    test "fails closed when the download's client cannot be resolved", %{tmp_dir: tmp_dir} do
      # No DownloadClientConfig exists under this name (a renamed or deleted
      # client, entirely plausible in a self-hosted deployment reconfigured
      # by env vars, and these failed downloads can sit for weeks before
      # anyone opens the modal). We cannot prove save_path differs from
      # that client's shared root, so this must not enumerate it even
      # though save_path genuinely IS a shared directory with an unrelated
      # file in it.
      root = Path.join(tmp_dir, "shared")
      File.mkdir_p!(root)
      File.write!(Path.join(root, "Some.Other.Show.S01E01.mkv"), "unrelated")
      File.write!(Path.join(root, "Silo.S01E01.mkv"), "silo")

      download =
        download_fixture(%{
          download_client: "renamed-or-deleted-client-#{System.unique_integer([:positive])}",
          metadata: %{
            "save_path" => root,
            "import_candidates" => [
              %{
                "path" => Path.join(root, "Silo.S01E01.mkv"),
                "name" => "Silo.S01E01.mkv",
                "size" => 4
              }
            ]
          }
        })

      assert {:ok, :snapshot, [candidate]} = ImportCandidates.load(download)
      assert candidate["name"] == "Silo.S01E01.mkv"
    end

    test "does not probe on the live listing, even for a large non-video file",
         %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "live")
      File.mkdir_p!(dir)
      big = ImportCandidates.probe_size_floor() + 1
      File.write!(Path.join(dir, "payload.exe"), :binary.copy(<<0>>, big))

      client = client_with_unrelated_root(tmp_dir)

      download =
        download_fixture(%{
          download_client: client.name,
          metadata: %{
            "save_path" => dir,
            "import_candidates" => [
              %{"path" => Path.join(dir, "old.exe"), "name" => "old.exe", "size" => 1}
            ]
          }
        })

      assert {:ok, :live, [candidate]} = ImportCandidates.load(download)
      assert candidate["name"] == "payload.exe"
      assert candidate["skip_reason"] == "not_video_extension"
      # If the live path probed (as `build/3` normally does), this would be
      # a freshly computed verdict. There is no snapshot probe for this
      # path to restore, so its absence proves probing did not run.
      refute Map.has_key?(candidate, "probe")
    end

    test "restores a snapshot's stashed probe verdict on the live listing instead of recomputing",
         %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "live")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "payload.exe"), "x")

      stashed_probe = %{"status" => "video", "note" => "stashed"}
      client = client_with_unrelated_root(tmp_dir)

      download =
        download_fixture(%{
          download_client: client.name,
          metadata: %{
            "save_path" => dir,
            "import_candidates" => [
              %{
                "path" => Path.join(dir, "payload.exe"),
                "name" => "payload.exe",
                "size" => 1,
                "probe" => stashed_probe
              }
            ]
          }
        })

      assert {:ok, :live, [candidate]} = ImportCandidates.load(download)
      assert candidate["probe"] == stashed_probe
    end
  end

  ## Helpers

  # A resolvable download client config whose download_directory is
  # deliberately NOT under the caller's test directory, so
  # `shared_download_root?/2` can positively rule it out and a live listing
  # proceeds instead of failing closed.
  defp client_with_unrelated_root(tmp_dir) do
    download_client_config_fixture(%{download_directory: Path.join(tmp_dir, "elsewhere")})
  end
end
