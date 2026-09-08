defmodule Mydia.Streaming.DirectPlayIdleStopTest do
  use ExUnit.Case, async: true

  alias Mydia.Streaming.DirectPlaySession
  alias Mydia.Streaming.DirectPlaySession.State

  # `init/1` inserts a TranscodeJob and broadcasts, so it needs a real
  # media_file and user. The idle branch needs neither: it reads one timestamp
  # off the state and decides. Driving the callback directly pins the exit
  # reason without dragging the database into a test about a log line.
  defp state_idle_for(milliseconds) do
    %State{
      session_id: "session-under-test",
      media_file_id: Ecto.UUID.generate(),
      user_id: Ecto.UUID.generate(),
      mode: :direct,
      last_activity: DateTime.add(DateTime.utc_now(), -milliseconds, :millisecond)
    }
  end

  describe "reaching the idle deadline" do
    test "stops with :normal, so routine expiry is not logged as a crash" do
      # OTP reports any reason other than :normal/:shutdown as a crash, with a
      # full error report. Returning :timeout here put "** (stop) time out"
      # in the production log every time a viewer simply walked away, which
      # reads like a fault worth chasing and is not one.
      assert {:stop, :normal, _state} =
               DirectPlaySession.handle_info(:check_timeout, state_idle_for(:timer.hours(1)))
    end
  end

  describe "before the idle deadline" do
    test "keeps running and rearms the check" do
      assert {:noreply, %State{timeout_ref: ref}} =
               DirectPlaySession.handle_info(:check_timeout, state_idle_for(0))

      assert is_reference(ref)
    end
  end
end
