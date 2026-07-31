defmodule Mydia.Streaming.HlsSessionOffsetTest do
  use ExUnit.Case, async: true

  alias Mydia.Streaming.HlsSessionSupervisor

  describe "session_matches_offset?/2" do
    test "matches when the requested offset equals the running one" do
      assert HlsSessionSupervisor.session_matches_offset?(%{start_position: 600}, 600)
    end

    test "does not match a different offset" do
      refute HlsSessionSupervisor.session_matches_offset?(%{start_position: 0}, 4200)
    end

    test "treats metadata with no start_position as offset zero" do
      # Registry metadata is in-memory, but a session registered before this
      # field existed must not be mistaken for an offset session.
      assert HlsSessionSupervisor.session_matches_offset?(%{mode: :transcode}, 0)
      refute HlsSessionSupervisor.session_matches_offset?(%{mode: :transcode}, 4200)
    end
  end

  describe "await_deregistration/1" do
    test "waits for a terminated process's registry entry to clear" do
      session_key = {:test_await_deregistration, make_ref()}
      test_pid = self()

      spawned_pid =
        spawn(fn ->
          Registry.register(Mydia.Streaming.HlsSessionRegistry, session_key, %{})
          send(test_pid, :registered)

          receive do
            :stop -> :ok
          end
        end)

      assert_receive :registered

      Process.exit(spawned_pid, :kill)

      assert HlsSessionSupervisor.await_deregistration(session_key) == :ok
      assert Registry.lookup(Mydia.Streaming.HlsSessionRegistry, session_key) == []
    end
  end

  describe "concurrent registration race" do
    # HlsSession.init/1 fetches a real media file via Library.get_media_file!/2
    # before it ever reaches the Registry.register call whose race we're
    # closing, and the winning branch spawns a real FFmpeg process. Driving
    # this scenario through the real HlsSession/HlsSessionSupervisor stack
    # would need DB fixtures and an actual transcode, so — matching the
    # existing convention in this directory (see hls_session_ready_test.exs's
    # MockSession and ffmpeg_ready_callback_test.exs's check_playlist_ready
    # helper) — this uses a minimal GenServer that reproduces HlsSession's
    # register-or-stop logic without either dependency.
    defmodule RaceProneSession do
      @moduledoc false
      use GenServer

      def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

      @impl true
      def init(opts) do
        key = Keyword.fetch!(opts, :key)

        case Registry.register(Mydia.Streaming.HlsSessionRegistry, key, %{}) do
          {:ok, _owner} -> {:ok, %{}}
          {:error, {:already_registered, pid}} -> {:stop, {:already_registered, pid}}
        end
      end
    end

    # Builds an explicit child spec with restart: :temporary, matching
    # HlsSession's real child spec in HlsSessionSupervisor.start_new_session/5.
    # Deliberately not using the {RaceProneSession, key: key} shorthand: that
    # relies on the child_spec/1 that `use GenServer` auto-generates, which
    # defaults to restart: :permanent. With :permanent, a loser stopping with
    # a non-normal reason would make the supervisor keep retrying (and
    # re-losing) the registration until it exhausted its restart intensity
    # and crashed — masking the very behavior this test verifies.
    defp race_child_spec(key) do
      %{
        id: make_ref(),
        start: {RaceProneSession, :start_link, [[key: key]]},
        restart: :temporary
      }
    end

    # Mirrors the translation in HlsSessionSupervisor.start_new_session/5: a
    # losing registration surfaces from DynamicSupervisor.start_child/2 as
    # {:error, reason}, where reason is exactly what the child's init/1
    # returned in its {:stop, reason} tuple. Adopt the winner's pid instead of
    # reporting failure.
    defp race_start(sup, key) do
      case DynamicSupervisor.start_child(sup, race_child_spec(key)) do
        {:error, {:already_registered, pid}} -> {:ok, pid}
        other -> other
      end
    end

    test "a losing init/1 stops instead of returning {:ok, state}" do
      {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one)
      key = {:race_test, make_ref()}

      {:ok, winner_pid} = DynamicSupervisor.start_child(sup, race_child_spec(key))

      # Confirms the exact shape DynamicSupervisor.start_child/2 surfaces when
      # a child's init/1 stops with {:stop, reason}: {:error, reason}, not a
      # crash and not a silently-accepted {:ok, pid}.
      assert {:error, {:already_registered, ^winner_pid}} =
               DynamicSupervisor.start_child(sup, race_child_spec(key))

      DynamicSupervisor.stop(sup)
    end

    test "two concurrent callers for the same key both adopt the single winner" do
      {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one)
      key = {:race_test, make_ref()}
      test_pid = self()

      for _ <- 1..2 do
        spawn(fn ->
          result = race_start(sup, key)
          send(test_pid, {:race_result, result})
        end)
      end

      assert_receive {:race_result, {:ok, pid1}}
      assert_receive {:race_result, {:ok, pid2}}

      assert pid1 == pid2
      assert [{^pid1, %{}}] = Registry.lookup(Mydia.Streaming.HlsSessionRegistry, key)

      DynamicSupervisor.stop(sup)
    end
  end
end
