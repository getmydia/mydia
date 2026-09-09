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
  end
end
