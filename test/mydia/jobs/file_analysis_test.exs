defmodule Mydia.Jobs.FileAnalysisTest do
  # Tests mutate Application env (ffprobe_path, file_analysis_*) so we run
  # them serially.
  use Mydia.DataCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  import Ecto.Query
  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Jobs.FileAnalysis
  alias Mydia.Library
  alias Mydia.Library.MediaFile
  alias Mydia.Library.Structs.FileMetadata
  alias Mydia.Repo

  setup do
    on_exit(fn ->
      Application.delete_env(:mydia, :ffprobe_path)
      Application.delete_env(:mydia, :ffprobe_timeout_ms)
      Application.delete_env(:mydia, :file_analysis_batch_size)
      Application.delete_env(:mydia, :file_analysis_max_attempts)
    end)

    :ok
  end

  describe "perform/1" do
    test "succeeds when no rows need analysis" do
      assert :ok = perform_job(FileAnalysis, %{})
    end

    test "analyzes un-analyzed rows and populates tech metadata" do
      {library_path, files} = seed_real_files(3, "u5_happy")

      shim = write_ok_shim(files |> hd() |> elem(1))

      try do
        Application.put_env(:mydia, :ffprobe_path, shim)

        assert :ok = perform_job(FileAnalysis, %{})

        for {media_file, _path} <- files do
          reloaded = Repo.get!(MediaFile, media_file.id)
          assert %DateTime{} = reloaded.analyzed_at
          assert reloaded.codec == "h264"
          assert reloaded.audio_codec == "aac"
          assert reloaded.resolution == "1080p"
          assert is_nil(reloaded.last_analysis_error)
        end

        assert Repo.aggregate(
                 from(mf in MediaFile,
                   where: mf.library_path_id == ^library_path.id and is_nil(mf.analyzed_at)
                 ),
                 :count
               ) == 0
      after
        File.rm(shim)
        Enum.each(files, fn {_mf, path} -> File.rm(path) end)
      end
    end

    test "respects the configured batch size cap" do
      Application.put_env(:mydia, :file_analysis_batch_size, 5)
      {_library_path, files} = seed_real_files(8, "u5_batch")

      shim = write_ok_shim(files |> hd() |> elem(1))

      try do
        Application.put_env(:mydia, :ffprobe_path, shim)

        assert :ok = perform_job(FileAnalysis, %{})

        analyzed_count =
          Repo.aggregate(
            from(mf in MediaFile, where: not is_nil(mf.analyzed_at)),
            :count
          )

        assert analyzed_count == 5,
               "expected exactly batch_size (5) rows analyzed, got #{analyzed_count}"

        # Second tick drains the remaining rows.
        assert :ok = perform_job(FileAnalysis, %{})

        assert Repo.aggregate(
                 from(mf in MediaFile, where: is_nil(mf.analyzed_at)),
                 :count
               ) == 0
      after
        File.rm(shim)
        Enum.each(files, fn {_mf, path} -> File.rm(path) end)
      end
    end

    test "skips rows past the attempt ceiling" do
      Application.put_env(:mydia, :file_analysis_max_attempts, 3)
      {_library_path, [{exhausted, _path} | _]} = seed_real_files(1, "u5_ceiling")

      Repo.update_all(
        from(mf in MediaFile, where: mf.id == ^exhausted.id),
        set: [analysis_attempts: 3, last_analysis_error: ":ffprobe_failed"]
      )

      # Even with a working shim, the row should not be picked up.
      shim = write_ok_shim("/nonexistent")

      try do
        Application.put_env(:mydia, :ffprobe_path, shim)

        assert :ok = perform_job(FileAnalysis, %{})

        reloaded = Repo.get!(MediaFile, exhausted.id)
        assert reloaded.analysis_attempts == 3
        assert is_nil(reloaded.analyzed_at)
      after
        File.rm(shim)
      end
    end

    test "bumps analysis_attempts and records the error on ffprobe failure" do
      {_library_path, [{media_file, _path}]} = seed_real_files(1, "u5_failure")

      shim = write_fail_shim()

      try do
        Application.put_env(:mydia, :ffprobe_path, shim)

        assert :ok = perform_job(FileAnalysis, %{})

        reloaded = Repo.get!(MediaFile, media_file.id)
        assert is_nil(reloaded.analyzed_at)
        assert reloaded.analysis_attempts == 1
        assert reloaded.last_analysis_error == ":ffprobe_failed"
      after
        File.rm(shim)
      end
    end

    test "repairs analyzed rows that are missing persisted dimensions" do
      {_library_path, [{media_file, path}]} = seed_real_files(1, "u5_repair")

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.update_all(
        from(mf in MediaFile, where: mf.id == ^media_file.id),
        set: [
          analyzed_at: now,
          resolution: "720p",
          codec: "hevc",
          audio_codec: "aac",
          metadata: %FileMetadata{container: "mkv", duration: 60.0}
        ]
      )

      shim = write_cropped_1080_shim(path)

      try do
        Application.put_env(:mydia, :ffprobe_path, shim)

        assert :ok = perform_job(FileAnalysis, %{})

        reloaded = Repo.get!(MediaFile, media_file.id)
        assert reloaded.resolution == "1080p"
        assert reloaded.metadata.width == 1920
        assert reloaded.metadata.height == 800
        assert %DateTime{} = reloaded.analyzed_at
        assert is_nil(reloaded.last_analysis_error)
      after
        File.rm(shim)
        File.rm(path)
      end
    end
  end

  describe "repair lane backfills streams" do
    test "selects an analyzed row that has dimensions but no streams" do
      media_file =
        media_file_fixture(%{
          analyzed_at: DateTime.utc_now() |> DateTime.truncate(:second),
          codec: "h264",
          resolution: "1080p",
          metadata: %Mydia.Library.Structs.FileMetadata{
            width: 1920,
            height: 1080,
            streams: nil
          }
        })

      rows = FileAnalysis.repair_rows_for_test(50, 3, [])

      assert Enum.any?(rows, &(&1.id == media_file.id))
    end

    test "does not select a row that already has streams" do
      media_file =
        media_file_fixture(%{
          analyzed_at: DateTime.utc_now() |> DateTime.truncate(:second),
          codec: "h264",
          resolution: "1080p",
          metadata: %Mydia.Library.Structs.FileMetadata{
            width: 1920,
            height: 1080,
            streams: [%Mydia.Library.Structs.StreamInfo{index: 0, type: :video, codec: "h264"}]
          }
        })

      rows = FileAnalysis.repair_rows_for_test(50, 3, [])

      refute Enum.any?(rows, &(&1.id == media_file.id))
    end

    test "the repair write matches a row that has dimensions but no streams" do
      media_file =
        media_file_fixture(%{
          analyzed_at: DateTime.utc_now() |> DateTime.truncate(:second),
          codec: "h264",
          resolution: "1080p",
          metadata: %Mydia.Library.Structs.FileMetadata{
            width: 1920,
            height: 1080,
            streams: nil
          }
        })

      result = %Mydia.Library.Structs.FileAnalysisResult{
        resolution: "1080p",
        codec: "H.264",
        width: 1920,
        height: 1080,
        streams: [%Mydia.Library.Structs.StreamInfo{index: 0, type: :video, codec: "h264"}]
      }

      assert :ok = Mydia.Library.apply_repair_analysis_for_test(media_file, result)

      reloaded = Mydia.Library.get_media_file!(media_file.id)
      assert [%Mydia.Library.Structs.StreamInfo{codec: "h264"}] = reloaded.metadata.streams
    end
  end

  describe "configuration wiring (source config/config.exs)" do
    # config/test.exs overrides Oban to `queues: false, plugins: false`, so we
    # read the upstream source config to verify the worker is wired for
    # non-test environments.
    setup do
      source =
        Config.Reader.read!(Path.expand("../../../config/config.exs", __DIR__), env: :prod)

      oban = get_in(source, [:mydia, Oban]) || []
      %{oban: oban}
    end

    test ":analysis queue is configured with concurrency 2", %{oban: oban} do
      assert Keyword.get(oban[:queues], :analysis) == 2
    end

    test "cron plugin includes the FileAnalysis worker every minute", %{oban: oban} do
      cron_plugin =
        Enum.find(oban[:plugins], fn
          {Oban.Plugins.Cron, _opts} -> true
          _ -> false
        end)

      assert {Oban.Plugins.Cron, opts} = cron_plugin
      crontab = Keyword.fetch!(opts, :crontab)

      assert Enum.any?(crontab, fn
               {"* * * * *", Mydia.Jobs.FileAnalysis} -> true
               {"* * * * *", Mydia.Jobs.FileAnalysis, _args} -> true
               _ -> false
             end),
             "expected {\"* * * * *\", Mydia.Jobs.FileAnalysis} in crontab"
    end
  end

  # Helpers

  defp seed_real_files(n, prefix) do
    dir = Path.join(System.tmp_dir!(), "u5_#{prefix}_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)

    library_path = library_path_fixture(%{path: dir, type: "movies"})

    rows =
      for i <- 1..n do
        relative = "file_#{i}.mkv"
        absolute = Path.join(dir, relative)
        File.write!(absolute, "fake video bytes for #{i}")

        {:ok, mf} =
          Library.create_scanned_media_file(%{
            relative_path: relative,
            library_path_id: library_path.id,
            size: File.stat!(absolute).size
          })

        {mf, absolute}
      end

    {library_path, rows}
  end

  defp write_ok_shim(reference_path) do
    size =
      case File.stat(reference_path) do
        {:ok, %{size: s}} -> s
        _ -> 1024
      end

    json =
      ~s({"streams":[{"codec_type":"video","codec_name":"h264","width":1920,"height":1080,"bit_rate":"8000000"},{"codec_type":"audio","codec_name":"aac"}],"format":{"duration":"5400.5","format_name":"matroska,webm","size":"#{size}","bit_rate":"8000000"}})

    path = Path.join(System.tmp_dir!(), "u5_ffprobe_ok_#{:rand.uniform(10_000_000)}.sh")
    escaped = String.replace(json, "'", "'\\''")
    File.write!(path, "#!/bin/sh\nprintf '%s' '#{escaped}'\n")
    File.chmod!(path, 0o755)
    path
  end

  defp write_cropped_1080_shim(reference_path) do
    size =
      case File.stat(reference_path) do
        {:ok, %{size: s}} -> s
        _ -> 1024
      end

    json =
      ~s({"streams":[{"codec_type":"video","codec_name":"hevc","width":1920,"height":800,"bit_rate":"8000000"},{"codec_type":"audio","codec_name":"aac"}],"format":{"duration":"5400.5","format_name":"matroska,webm","size":"#{size}","bit_rate":"8000000"}})

    path = Path.join(System.tmp_dir!(), "u5_ffprobe_repair_#{:rand.uniform(10_000_000)}.sh")
    escaped = String.replace(json, "'", "'\\''")
    File.write!(path, "#!/bin/sh\nprintf '%s' '#{escaped}'\n")
    File.chmod!(path, 0o755)
    path
  end

  defp write_fail_shim do
    path = Path.join(System.tmp_dir!(), "u5_ffprobe_fail_#{:rand.uniform(10_000_000)}.sh")
    File.write!(path, "#!/bin/sh\necho 'simulated failure' >&2\nexit 1\n")
    File.chmod!(path, 0o755)
    path
  end
end
