defmodule Mydia.Player.Supervisor do
  @moduledoc """
  Every process that exists only to serve the Mydia player.

  Started by `Mydia.Application` only while `Mydia.Player.enabled?/0` is true.
  Its place in the application's child list is load-bearing: after
  `Mydia.Config.Bootstrap`, so `Mydia.Streaming.HardwareAccel` and the
  remote-access subtree read the merged database layer, and before Oban and
  the Endpoint, which serve the jobs and requests that use these processes.

  `:one_for_one`, as these children were when they sat directly under
  `Mydia.Supervisor`.
  """
  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Supervisor.init(children(), strategy: :one_for_one)
  end

  @doc """
  The children, in start order. Public so a test can check that none of them
  is also started by `Mydia.Application`.
  """
  def children do
    hardware_accel_children() ++
      [
        # Separate named lock instance serializing session subtitle extraction
        # (see Mydia.Streaming.SessionSubtitles). A slow ffmpeg extraction must
        # never make a plugin invocation wait behind it, hence its own instance
        # rather than sharing the plugin host's lock. The explicit :id
        # disambiguates it from the plugin host's SingleFlight child: both
        # default to the module name as their child id.
        Supervisor.child_spec({Mydia.Plugins.SingleFlight, name: Mydia.Streaming.SubtitleLock},
          id: Mydia.Streaming.SubtitleLock
        ),
        {Registry, keys: :unique, name: Mydia.Streaming.HlsSessionRegistry},
        Mydia.Streaming.HlsSessionSupervisor,
        {Registry, keys: :unique, name: Mydia.Downloads.TranscodeRegistry},
        Mydia.Downloads.JobManager,
        Mydia.Player.RemoteAccess.Supervisor
      ]
  end

  # Probes the host's video hardware once and caches the answer. Probing costs
  # one to three seconds and runs in handle_continue, so it delays only the
  # first caller asking for capabilities, not the rest of the tree.
  #
  # Not started under `mix test`. A developer machine with a real render node
  # would otherwise hand hardware capabilities to every streaming test, and
  # those tests assert software arguments on purpose: they are what proves the
  # accelerated path did not change the unaccelerated one. capabilities/0
  # reports software when this process is absent, so nothing else needs to
  # know.
  defp hardware_accel_children do
    if Application.get_env(:mydia, :start_health_monitors, true) do
      [Mydia.Streaming.HardwareAccel]
    else
      []
    end
  end
end
