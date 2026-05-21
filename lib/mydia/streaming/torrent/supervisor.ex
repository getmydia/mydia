defmodule Mydia.Streaming.Torrent.Supervisor do
  @moduledoc """
  Dedicated supervisor for the torrent streaming subsystem.

  Uses `:rest_for_one` so that if the Engine crashes, the SessionSupervisor
  (and all its dynamic Session children) is terminated and restarted with a
  fresh Engine resource. Stale ResourceArc references held by old Session
  GenServers would otherwise point at a dead librqbit handle, which crashes
  on the next read_chunk.

  Children order matters:

    1. `TorrentSessionRegistry` — both Engine and Sessions look up via it.
    2. `Engine` — owns the Rust NIF resource.
    3. `SessionSupervisor` — dynamic supervisor of per-stream `Session`
       GenServers, which hold a `ResourceArc` cloned from the Engine.

  Coupled with the boot-time reap in `Mydia.Application.cleanup_stale_torrent_sessions/0`,
  every Engine restart starts with no in-memory sessions and any DB rows that
  were active before the crash have been transitioned to `:failed`.
  """

  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      {Registry, keys: :unique, name: Mydia.Streaming.TorrentSessionRegistry},
      Mydia.Streaming.Torrent.Engine,
      Mydia.Streaming.Torrent.SessionSupervisor
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
