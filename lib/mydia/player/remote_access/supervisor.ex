defmodule Mydia.Player.RemoteAccess.Supervisor do
  @moduledoc """
  The p2p node and everything pairing needs.

  A child of `Mydia.Player.Supervisor`. `Mydia.Player.RemoteAccess.sync/2`
  stops and restarts it when the admin toggle changes. `init/1` returns
  `:ignore` while remote access is off, which keeps the child spec in the
  parent, so `Supervisor.restart_child/2` can start it later.

  Options, for tests:

    * `:name` - registered name, this module by default; `nil` registers none
    * `:children` - replaces `default_children/0`
    * `:start?` - zero-arity function deciding whether to start, by default
      `Mydia.Player.RemoteAccess.refresh/0`
  """
  use Supervisor

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @impl true
  def init(opts) do
    start? = Keyword.get(opts, :start?, &Mydia.Player.RemoteAccess.refresh/0)

    if start?.() do
      opts
      |> Keyword.get_lazy(:children, &default_children/0)
      |> Supervisor.init(strategy: :one_for_one)
    else
      :ignore
    end
  end

  @doc "The remote-access processes, in start order."
  def default_children do
    [
      # Must precede P2p.Server: it creates the instance identity the p2p node
      # and every pairing depend on.
      Mydia.RemoteAccess.Provision,
      # Rate-limits pairing-claim validation. Its ETS table has no reason to
      # exist while pairing cannot happen.
      Mydia.RemoteAccess.ClaimRateLimiter,
      # Serves peer requests off Mydia.P2p.Server. Bounded because iroh gates
      # inbound connections on ALPN alone, so a peer needs no credential to
      # make the host spawn these, and `max_children` is what keeps that from
      # becoming the third memory-exhaustion hole in this subsystem. Over the
      # limit the request is refused rather than queued.
      #
      # Two children per in-flight request, so this caps concurrency at 256:
      # one runs the handler, the other waits on it with a deadline and kills
      # it if it hangs. A handler blocked on an unresponsive filesystem
      # returns on its own schedule or never, and a bound whose slots never
      # come back just fails every later request instead.
      {Task.Supervisor, name: Mydia.P2p.RequestSupervisor, max_children: 512},
      # HLS byte-serving, kept off RequestSupervisor on purpose. These tasks
      # are long-lived where a request handler is not: one may sit in
      # `HlsSession.await_ready/2` for the whole readiness budget waiting on a
      # cold encoder, then stream a segment. Sharing the request pool would let
      # a stalled encoder's backlog fill it and start refusing GraphQL, so the
      # two get separate budgets and a stream backlog can only exhaust its own.
      #
      # One child per in-flight stream request here, not two, since nothing
      # wraps these with a deadline: the readiness wait is the bound.
      {Task.Supervisor, name: Mydia.P2p.StreamSupervisor, max_children: 256},
      Mydia.P2p.Server,
      # Resume active pairing claims on startup
      Mydia.RemoteAccess.ResumeClaims
    ]
  end
end
