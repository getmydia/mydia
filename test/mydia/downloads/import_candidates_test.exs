defmodule Mydia.Downloads.ImportCandidatesTest do
  use Mydia.DataCase, async: true

  import Mydia.DownloadsFixtures
  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Downloads.ImportCandidates

  @moduletag :tmp_dir

  defp file(tmp_dir, name, size) do
    path = Path.join(tmp_dir, name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, :binary.copy(<<0>>, size))
    %{path: path, name: name, size: size}
  end

  # Same contract as `file/3`, but produces a sparse file: `File.stat!/1`
  # reports `size` bytes, while the actual disk blocks consumed are close to
  # zero. Used by tests that only need to clear `probe_size_floor/0` — the
  # bytes themselves are never read for content, only counted, so writing
  # `size` real bytes to disk buys nothing but I/O pressure. Seeking to the
  # last byte and writing it is what makes the file sparse: the filesystem
  # only allocates blocks for ranges that were actually written, and the gap
  # before that final byte is reported as zeros without being stored.
  defp sparse_file(tmp_dir, name, size) do
    path = Path.join(tmp_dir, name)
    File.mkdir_p!(Path.dirname(path))

    {:ok, fd} = :file.open(path, [:write, :binary])
    {:ok, _} = :file.position(fd, size - 1)
    :ok = :file.write(fd, <<0>>)
    :ok = :file.close(fd)

    %{path: path, name: name, size: size}
  end

  test "flags a non-video extension and probes it", %{tmp_dir: tmp_dir} do
    big = ImportCandidates.probe_size_floor() + 1
    files = [sparse_file(tmp_dir, "payload.exe", big)]

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
        sparse_file(tmp_dir, "payload#{i}.exe", big)
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

    test "skips a listed entry that cannot be stat'd instead of crashing", %{tmp_dir: tmp_dir} do
      # The bug this fixes is a TOCTOU race: the old implementation checked
      # `File.regular?/1` in one pass, then called `File.stat!/1` on the
      # survivors in a second pass — two separate filesystem checks on the
      # same path, with a window between them where the file could be
      # deleted or renamed out from under it (plausible in a self-hosted
      # deployment where the operator or the download client can be
      # touching the same folder while the modal is open). `File.stat!/1`
      # raises if that happens, crashing the modal open. The fix collapses
      # both checks into a single `File.stat/1` call, which structurally
      # eliminates the window rather than narrowing it.
      #
      # That two-syscall race needs real concurrency to reproduce
      # deterministically (something deleting the file at the exact moment
      # `list_recursive/1` is between its two filesystem calls), so it is
      # not what this test proves and no attempt is made to simulate it
      # here. Instead, this pins the narrower property the fix also
      # guarantees on the same code path: an entry the directory listing
      # surfaces that `File.stat/1` cannot confirm is skipped rather than
      # raising. A broken symlink stands in for that: `Path.wildcard/2`
      # lists it (a directory listing does not resolve symlink targets),
      # but `File.stat/1` (which follows symlinks) cannot resolve it. Note
      # this particular case was already handled by the old code too —
      # `File.regular?/1` also follows symlinks, so it already returned
      # `false` and filtered the broken symlink out before `File.stat!/1`
      # ever ran on it. This is not a regression test for the TOCTOU race.
      dir = Path.join(tmp_dir, "live")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "keep.mkv"), "x")
      File.ln_s!(Path.join(dir, "does-not-exist.mkv"), Path.join(dir, "ghost.mkv"))

      client = client_with_unrelated_root(tmp_dir)

      download =
        download_fixture(%{
          download_client: client.name,
          metadata: %{
            "save_path" => dir,
            "import_candidates" => [
              %{"path" => Path.join(dir, "old.mkv"), "name" => "old.mkv", "size" => 1}
            ]
          }
        })

      assert {:ok, :live, candidates} = ImportCandidates.load(download)
      assert Enum.map(candidates, & &1["name"]) == ["keep.mkv"]
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

    test "uses the download's resolved library_path type over the media_item guess",
         %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "live")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "track.nfo"), "x")

      client = client_with_unrelated_root(tmp_dir)
      # `library_type_for/1`'s guess only ever returns :movies or :series from
      # `media_item.type`, and a "tv_show" media_item guesses :series — under
      # which a `.nfo` file fails the extension filter (skip_reason
      # "not_video_extension"). Resolving the real, non-guessable `:music`
      # library type instead makes the SAME file pass (Mydia no longer owns
      # an extension vocabulary for it, so `importable?/2` treats it as
      # always importable), proving the resolved type won.
      library_path = library_path_fixture(%{type: "music"})
      media_item = media_item_fixture(%{type: "tv_show"})

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          download_client: client.name,
          library_path_id: library_path.id,
          metadata: %{
            "save_path" => dir,
            "import_candidates" => [
              %{"path" => Path.join(dir, "old.mkv"), "name" => "old.mkv", "size" => 1}
            ]
          }
        })
        |> Repo.preload(:library_path)

      assert {:ok, :live, [candidate]} = ImportCandidates.load(download)
      assert candidate["name"] == "track.nfo"
      assert candidate["skip_reason"] == nil
    end

    test "falls back to the media_item guess when library_path isn't preloaded",
         %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "live")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "track.mkv"), "x")

      client = client_with_unrelated_root(tmp_dir)
      # The library_path's type is irrelevant here: it is deliberately left
      # unpreloaded below, so `resolved_library_type/1` never reads it.
      library_path = library_path_fixture(%{type: "movies"})
      media_item = media_item_fixture(%{type: "tv_show"})

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          download_client: client.name,
          library_path_id: library_path.id,
          metadata: %{
            "save_path" => dir,
            "import_candidates" => [
              %{"path" => Path.join(dir, "old.mkv"), "name" => "old.mkv", "size" => 1}
            ]
          }
        })

      # No `Repo.preload(:library_path)`: an unloaded association must fall
      # back to the guess rather than raise `FunctionClauseError`.
      assert {:ok, :live, [candidate]} = ImportCandidates.load(download)
      assert candidate["name"] == "track.mkv"
      assert candidate["skip_reason"] == nil
    end

    test "does not probe on the live listing, even for a large non-video file",
         %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "live")
      File.mkdir_p!(dir)
      big = ImportCandidates.probe_size_floor() + 1
      sparse_file(dir, "payload.exe", big)

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

    test "restores the snapshot's parsed season/episode on the live listing instead of a bare re-parse",
         %{tmp_dir: tmp_dir} do
      # A bare re-parse (the `parser_opts: []` `merge/3` always uses for a
      # live listing) of this name yields season 3, episode 6 — see "leaves
      # an importable file unflagged and records the parser guess" above.
      # The failure-time snapshot was parsed by `MediaImport` with the
      # download's real parser opts (a `TargetContext` built from its bound
      # media item) and landed on season 1, episode 1 instead — a
      # legitimate difference, e.g. for an absolute-numbered release the
      # TargetContext maps against the show's actual episode list. Without
      # restoring the snapshot's values, the operator would see a different
      # prefilled episode for the same file depending on whether the modal
      # happened to get a live listing or fell back to the snapshot.
      dir = Path.join(tmp_dir, "live")
      File.mkdir_p!(dir)
      known_name = "Some.Show.S03E06.1080p.WEB-DL.mkv"
      File.write!(Path.join(dir, known_name), "x")

      # Genuinely new on disk since the failure, so absent from the
      # snapshot — there is nothing to restore, and it must keep its fresh
      # re-parse rather than being blanked out.
      new_name = "Some.Show.S02E04.1080p.WEB-DL.mkv"
      File.write!(Path.join(dir, new_name), "y")

      client = client_with_unrelated_root(tmp_dir)

      download =
        download_fixture(%{
          download_client: client.name,
          metadata: %{
            "save_path" => dir,
            "import_candidates" => [
              %{
                "path" => Path.join(dir, known_name),
                "name" => known_name,
                "size" => 1,
                "parsed_season" => 1,
                "parsed_episode" => 1
              }
            ]
          }
        })

      assert {:ok, :live, candidates} = ImportCandidates.load(download)
      by_name = Map.new(candidates, &{&1["name"], &1})

      assert by_name[known_name]["parsed_season"] == 1
      assert by_name[known_name]["parsed_episode"] == 1

      assert by_name[new_name]["parsed_season"] == 2
      assert by_name[new_name]["parsed_episode"] == 4
    end

    test "falls back to metadata[\"unresolved_files\"] when there is no import_candidates snapshot",
         %{tmp_dir: tmp_dir} do
      # Every unresolved-files download that existed before the
      # import_candidates snapshot shipped only has this key. There is
      # deliberately no "save_path" here (and no resolvable client), so this
      # exercises the pure snapshot fallback, not a live re-listing.
      missing_path = Path.join(tmp_dir, "gone/Show.S01E02.mkv")

      download =
        download_fixture(%{
          metadata: %{
            "unresolved_files" => [
              %{
                "path" => missing_path,
                "name" => "Show.S01E02.mkv",
                "size" => 123,
                "parsed_season" => 1,
                "parsed_episode" => 2,
                "assigned_episode_id" => nil
              }
            ]
          }
        })

      assert {:ok, :snapshot, [candidate]} = ImportCandidates.load(download)
      assert candidate["path"] == missing_path
      assert candidate["name"] == "Show.S01E02.mkv"
      assert candidate["size"] == 123
      assert candidate["parsed_season"] == 1
      assert candidate["parsed_episode"] == 2
      assert candidate["skip_reason"] == nil
      assert candidate["missing"] == true
    end

    test "derives a name from the path when unresolved_files omits it", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "Show.S01E02.mkv")
      File.write!(path, "x")

      download =
        download_fixture(%{
          metadata: %{"unresolved_files" => [%{"path" => path}]}
        })

      assert {:ok, :snapshot, [candidate]} = ImportCandidates.load(download)
      assert candidate["name"] == "Show.S01E02.mkv"
      assert candidate["missing"] == false
    end

    test "prefers import_candidates over unresolved_files when both are present" do
      download =
        download_fixture(%{
          metadata: %{
            "import_candidates" => [
              %{"path" => "/tmp/a.mkv", "name" => "a.mkv", "size" => 1}
            ],
            "unresolved_files" => [
              %{"path" => "/tmp/b.mkv", "name" => "b.mkv", "size" => 2}
            ]
          }
        })

      assert {:ok, :snapshot, [candidate]} = ImportCandidates.load(download)
      assert candidate["name"] == "a.mkv"
    end

    test "still reports unavailable when neither key is present" do
      download = download_fixture(%{metadata: %{"unresolved_files" => nil}})

      assert {:error, :unavailable} = ImportCandidates.load(download)
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
