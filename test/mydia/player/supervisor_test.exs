defmodule Mydia.Player.SupervisorTest do
  # async: false - the player switch and :start_health_monitors are app env.
  use ExUnit.Case, async: false

  import Mydia.PlayerHelpers

  # Every process that exists only to serve the player. None of them may be
  # started by Mydia.Application directly.
  @player_only [
    Mydia.Streaming.HardwareAccel,
    Mydia.Streaming.SubtitleLock,
    Mydia.Streaming.HlsSessionRegistry,
    Mydia.Streaming.HlsSessionSupervisor,
    Mydia.Downloads.TranscodeRegistry,
    Mydia.Downloads.JobManager,
    Mydia.Player.RemoteAccess.Supervisor,
    Mydia.RemoteAccess.Provision,
    Mydia.RemoteAccess.ClaimRateLimiter,
    Mydia.P2p.RequestSupervisor,
    Mydia.P2p.StreamSupervisor,
    Mydia.P2p.Server,
    Mydia.RemoteAccess.ResumeClaims
  ]

  # A child spec names its process as the module itself, through a :name
  # option (Registry, Task.Supervisor), or through an explicit :id.
  defp names(children) do
    Enum.flat_map(children, fn
      module when is_atom(module) -> [module]
      {module, opts} when is_list(opts) -> [module, Keyword.get(opts, :name)]
      {module, _arg} -> [module]
      %{id: id, start: {module, _fun, _args}} -> [id, module]
    end)
  end

  defp held do
    names(Mydia.Player.Supervisor.children()) ++
      names(Mydia.Player.RemoteAccess.Supervisor.default_children())
  end

  test "Mydia.Application starts none of the player's processes itself" do
    started = names(Mydia.Application.children(queues: [default: 1]))

    for name <- @player_only do
      refute name in started, "#{inspect(name)} belongs under Mydia.Player.Supervisor"
    end
  end

  test "the player's subtree holds every one of them" do
    previous = Application.get_env(:mydia, :start_health_monitors)
    Application.put_env(:mydia, :start_health_monitors, true)
    on_exit(fn -> Application.put_env(:mydia, :start_health_monitors, previous) end)

    for name <- @player_only do
      assert name in held(), "#{inspect(name)} is missing from the player subtree"
    end
  end

  test "with the player on, the application starts the player subtree and subscriptions" do
    children = Mydia.Application.children(queues: [default: 1])

    assert Mydia.Player.Supervisor in children
    assert Enum.any?(children, &match?({Absinthe.Subscription, _}, &1))
  end

  test "with the player off, it starts neither" do
    disable_player()
    children = Mydia.Application.children(queues: [default: 1])

    refute Mydia.Player.Supervisor in children
    refute Enum.any?(children, &match?({Absinthe.Subscription, _}, &1))
  end

  describe "Mydia.Player.RemoteAccess.Supervisor" do
    test "ignores at boot when told not to start, so the parent keeps its spec" do
      assert :ignore =
               Mydia.Player.RemoteAccess.Supervisor.init(start?: fn -> false end, children: [])
    end

    test "starts the given children when told to" do
      assert {:ok, {_flags, [_child]}} =
               Mydia.Player.RemoteAccess.Supervisor.init(
                 start?: fn -> true end,
                 children: [{Agent, fn -> :stub end}]
               )
    end
  end
end
