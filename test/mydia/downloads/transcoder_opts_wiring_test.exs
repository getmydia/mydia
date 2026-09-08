defmodule Mydia.Downloads.TranscoderOptsWiringTest do
  @moduledoc """
  Pins the wiring that carries `:source_codec` from the source media file all
  the way to the ffmpeg transcoder, rather than only asserting on end-to-end
  behaviour.

  Without `:source_codec`, `Mydia.Streaming.HardwareAccel.Args.build/2` never
  sees a decodable source, `Capabilities.can_decode?/2` fails closed, and
  every download resolves to the `:hybrid` tier forever -- even on hardware
  that can decode the source -- which is a large, silent performance
  regression, not a crash. A prior task in this plan shipped exactly this
  shape of bug (a key silently dropped by a function that rebuilt its options
  from a fixed whitelist) with every existing test passing, because nothing
  asserted on the opts a downstream collaborator actually received.
  """

  use Mydia.DataCase, async: false

  alias Mydia.Downloads.CapturingTranscoder
  alias Mydia.Downloads.DownloadService
  alias Mydia.Downloads.JobManager

  setup do
    previous = Application.get_env(:mydia, :transcoder_module)
    Application.put_env(:mydia, :transcoder_module, CapturingTranscoder)

    cleanup_jobs()
    CapturingTranscoder.collect()

    on_exit(fn ->
      cleanup_jobs()

      case previous do
        nil -> Application.delete_env(:mydia, :transcoder_module)
        mod -> Application.put_env(:mydia, :transcoder_module, mod)
      end
    end)

    :ok
  end

  describe "JobManager.start_or_queue_job/1" do
    test "the immediate-start path forwards opts to the transcoder unchanged" do
      {:ok, pid} =
        JobManager.start_or_queue_job(
          media_file_id: "wiring-immediate",
          resolution: :p720,
          input_path: "/tmp/in.mkv",
          output_path: "/tmp/out.mp4",
          source_codec: "hevc"
        )

      assert_receive {:transcoder_opts, opts}
      assert Keyword.get(opts, :source_codec) == "hevc"

      JobManager.cancel_job("wiring-immediate", :p720)
      assert is_pid(pid)
    end

    test "a job promoted from the queue still carries :source_codec" do
      # Fill capacity (default max_concurrent: 2) with jobs that stay alive
      # until told to finish, so the third job is forced into the queue --
      # queued_job.opts is a separate storage path from the immediate-start
      # one, and both must preserve the same keys.
      {:ok, pid1} =
        JobManager.start_or_queue_job(
          media_file_id: "wiring-fill-1",
          resolution: :p720,
          input_path: "/tmp/in1.mkv",
          output_path: "/tmp/out1.mp4",
          source_codec: "h264"
        )

      {:ok, _pid2} =
        JobManager.start_or_queue_job(
          media_file_id: "wiring-fill-2",
          resolution: :p720,
          input_path: "/tmp/in2.mkv",
          output_path: "/tmp/out2.mp4",
          source_codec: "h264"
        )

      # Drain the two capture messages from the immediate starts above before
      # asserting on the queued job's message below.
      assert_receive {:transcoder_opts, _fill_1}
      assert_receive {:transcoder_opts, _fill_2}

      {:ok, :queued} =
        JobManager.start_or_queue_job(
          media_file_id: "wiring-queued",
          resolution: :p720,
          input_path: "/tmp/in3.mkv",
          output_path: "/tmp/out3.mp4",
          source_codec: "hevc"
        )

      refute_receive {:transcoder_opts, _}, 100

      # Free a slot so the queued job is promoted.
      CapturingTranscoder.finish(pid1)

      assert_receive {:transcoder_opts, promoted_opts}, 5_000
      assert Keyword.get(promoted_opts, :source_codec) == "hevc"

      JobManager.cancel_job("wiring-fill-2", :p720)
      JobManager.cancel_job("wiring-queued", :p720)
    end
  end

  describe "DownloadService.prepare_by_file/2" do
    setup do
      library = insert(:library_path, type: :movies, path: "/movies")
      media_item = insert(:media_item, type: "movie")

      media_file =
        insert(:media_file,
          media_item: media_item,
          library_path: library,
          relative_path: "movie.mkv",
          size: 1_000_000_000,
          resolution: "1080p",
          codec: "hevc"
        )

      %{media_file: media_file}
    end

    test "threads the source media file's codec through to the transcoder", %{
      media_file: media_file
    } do
      assert {:ok, _job_info} = DownloadService.prepare_by_file(media_file.id, "720p")

      assert_receive {:transcoder_opts, opts}, 5_000
      assert Keyword.get(opts, :source_codec) == "hevc"

      # cleanup_jobs/0 in on_exit cancels this via JobManager (keyed on
      # media_file_id + resolution, same as DownloadService used to start
      # it); no need to cancel it here.
    end
  end

  defp cleanup_jobs do
    %{active: active, queued: queued} = JobManager.list_active_jobs()

    Enum.each(active ++ queued, fn job ->
      JobManager.cancel_job(job.media_file_id, job.resolution)
    end)

    wait_for_registry_cleanup()
  end

  defp wait_for_registry_cleanup(attempts_left \\ 20)

  defp wait_for_registry_cleanup(0) do
    registry_entries()
    |> Enum.each(fn [_key, pid, _value] ->
      if Process.alive?(pid) do
        GenServer.stop(pid, :normal)
      end
    end)

    Process.sleep(100)
  end

  defp wait_for_registry_cleanup(attempts_left) do
    case registry_entries() do
      [] ->
        :ok

      _entries ->
        Process.sleep(50)
        wait_for_registry_cleanup(attempts_left - 1)
    end
  end

  defp registry_entries do
    Registry.select(Mydia.Downloads.TranscodeRegistry, [{{:"$1", :"$2", :"$3"}, [], [:"$$"]}])
  end
end
