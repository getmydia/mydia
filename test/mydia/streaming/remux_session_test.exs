defmodule Mydia.Streaming.RemuxSessionTest do
  @moduledoc """
  A remuxing viewer used to be invisible: stream_file_remux/3 opened a chunked
  response and registered nothing, so Now Playing showed an empty dashboard
  while FFmpeg repackaged a file.
  """
  use Mydia.DataCase, async: false

  alias Mydia.MediaFixtures
  alias Mydia.Streaming.DirectPlaySession
  alias Mydia.Streaming.HlsSessionSupervisor
  alias Mydia.Streaming.StreamPlan

  defp plan_for(media_file), do: StreamPlan.for_remux(media_file, [])

  describe "start_remux_session/3" do
    test "registers a session carrying its plan" do
      media_file = MediaFixtures.media_file_fixture(%{bitrate: 4_200_000})
      user = Mydia.AccountsFixtures.user_fixture()

      {:ok, pid, :started} =
        HlsSessionSupervisor.start_remux_session(media_file.id, user.id, plan_for(media_file))

      on_exit(fn -> HlsSessionSupervisor.stop_remux_session(media_file.id, user.id) end)

      {:ok, info} = DirectPlaySession.get_info(pid)

      assert info.kind == :remux
      assert info.plan.container == :fmp4
      assert info.plan.video.action == :copy
    end

    test "a second request reuses the running session" do
      # A browser seek aborts the request and immediately opens another.
      # Starting a fresh session there would churn out a second card and a
      # second job row for one viewer.
      media_file = MediaFixtures.media_file_fixture(%{})
      user = Mydia.AccountsFixtures.user_fixture()

      {:ok, first, :started} =
        HlsSessionSupervisor.start_remux_session(media_file.id, user.id, plan_for(media_file))

      {:ok, second, :existing} =
        HlsSessionSupervisor.start_remux_session(media_file.id, user.id, plan_for(media_file))

      on_exit(fn -> HlsSessionSupervisor.stop_remux_session(media_file.id, user.id) end)

      assert first == second
    end

    test "a direct session for the same file and user is a separate session" do
      # Different registry keys, so a viewer who direct-plays one file and
      # remuxes another is two cards, not one overwriting the other.
      media_file = MediaFixtures.media_file_fixture(%{})
      user = Mydia.AccountsFixtures.user_fixture()

      {:ok, remux, :started} =
        HlsSessionSupervisor.start_remux_session(media_file.id, user.id, plan_for(media_file))

      {:ok, direct, :started} =
        HlsSessionSupervisor.start_direct_session(media_file.id, user.id)

      on_exit(fn ->
        HlsSessionSupervisor.stop_remux_session(media_file.id, user.id)
        HlsSessionSupervisor.stop_direct_session(media_file.id, user.id)
      end)

      refute remux == direct

      {:ok, direct_info} = DirectPlaySession.get_info(direct)
      assert direct_info.kind == :direct
      assert direct_info.plan == nil
    end

    test "reusing the session refreshes its plan" do
      # A seek reopens the stream, and the new request can resolve a different
      # audio track. Keeping the plan the session started with would put the
      # dashboard back to describing an encode that is not the one running,
      # which is the whole defect this feature removes.
      media_file = MediaFixtures.media_file_fixture(%{})
      user = Mydia.AccountsFixtures.user_fixture()

      first = plan_for(media_file)
      second = %{first | audio: %{first.audio | from_codec: "eac3", action: :encode}}

      {:ok, pid, :started} =
        HlsSessionSupervisor.start_remux_session(media_file.id, user.id, first)

      on_exit(fn -> HlsSessionSupervisor.stop_remux_session(media_file.id, user.id) end)

      {:ok, ^pid, :existing} =
        HlsSessionSupervisor.start_remux_session(media_file.id, user.id, second)

      {:ok, info} = DirectPlaySession.get_info(pid)
      assert info.plan.audio.action == :encode
      assert info.plan.audio.from_codec == "eac3"

      # The registry copy too: list_active_sessions/0 falls back to it when the
      # process call races a shutdown, so refreshing only the process state
      # would leave a path that still reports the stale plan.
      [{^pid, meta}] =
        Registry.lookup(
          Mydia.Streaming.HlsSessionRegistry,
          {:remux_session, media_file.id, user.id}
        )

      assert meta.plan.audio.action == :encode
    end

    test "stopping the session removes its playing job row" do
      # DirectPlaySession does not trap exits, so stopping it through
      # DynamicSupervisor.terminate_child/2 would skip terminate/2 and strand
      # the "playing" TranscodeJob in the queue UI forever.
      media_file = MediaFixtures.media_file_fixture(%{})
      user = Mydia.AccountsFixtures.user_fixture()

      {:ok, _pid, :started} =
        HlsSessionSupervisor.start_remux_session(media_file.id, user.id, plan_for(media_file))

      assert Mydia.Repo.exists?(
               from(j in Mydia.Downloads.TranscodeJob,
                 where: j.media_file_id == ^media_file.id and j.type == "remux"
               )
             )

      :ok = HlsSessionSupervisor.stop_remux_session(media_file.id, user.id)

      refute Mydia.Repo.exists?(
               from(j in Mydia.Downloads.TranscodeJob,
                 where: j.media_file_id == ^media_file.id and j.type == "remux"
               )
             )
    end
  end
end
