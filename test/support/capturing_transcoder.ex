defmodule Mydia.Downloads.CapturingTranscoder do
  @moduledoc """
  Deterministic stand-in for `Mydia.Downloads.FfmpegMp4Transcoder`, combining
  `Mydia.Downloads.BlockingTranscoder`'s job-manager-friendly lifecycle (stays
  alive, occupying a capacity slot, until told to finish or stopped) with
  capturing the exact opts `start_transcoding/1` was called with.

  Exists to pin the *wiring* between `DownloadService`, `JobManager`, and the
  real transcoder: a test can assert on the opts a transcoder actually
  received, rather than only on end-to-end behaviour that could pass for the
  wrong reason (e.g. a dropped `:source_codec` silently degrading hardware
  acceleration to a slower tier while still producing correct video). A prior
  task in this plan shipped exactly this shape of bug -- a key placed in an
  opts keyword list silently dropped because a downstream function rebuilt
  its options from a fixed whitelist -- and every behavioural test still
  passed, because nothing asserted on the opts themselves.

  Call `collect/0` from the test process before triggering a job to receive
  `{:transcoder_opts, opts}` for every subsequent `start_transcoding/1` call,
  immediate or promoted from the queue.
  """

  use GenServer

  @collector_name Mydia.Downloads.CapturingTranscoder.Collector

  @doc "Starts a transcoder that captures its opts and stays alive until stopped."
  @spec start_transcoding(keyword()) :: GenServer.on_start()
  def start_transcoding(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Stops the transcoder process (simulates a cancelled job)."
  @spec stop_transcoding(pid()) :: :ok
  def stop_transcoding(pid) do
    GenServer.stop(pid, :normal)
  end

  @doc """
  Simulates a finished transcode: invokes `:on_complete` (if any) and exits
  normally, so `JobManager` frees the slot and starts the next queued job.
  """
  @spec finish(pid()) :: :ok
  def finish(pid) do
    GenServer.cast(pid, :finish)
  end

  @doc """
  Registers the calling process under a fixed name so every subsequent
  `start_transcoding/1` call sends it `{:transcoder_opts, opts}`.

  Registration is torn down automatically when the calling (test) process
  exits, so no explicit cleanup is required between tests.
  """
  @spec collect() :: :ok
  def collect do
    Process.register(self(), @collector_name)
    :ok
  end

  @impl true
  def init(opts) do
    case Process.whereis(@collector_name) do
      nil -> :ok
      pid -> send(pid, {:transcoder_opts, opts})
    end

    {:ok, %{on_complete: Keyword.get(opts, :on_complete)}}
  end

  @impl true
  def handle_cast(:finish, %{on_complete: on_complete} = state) do
    if is_function(on_complete, 0), do: on_complete.()
    {:stop, :normal, state}
  end
end
