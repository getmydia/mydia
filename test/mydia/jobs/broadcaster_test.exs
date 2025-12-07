defmodule Mydia.Jobs.BroadcasterTest do
  use Mydia.DataCase, async: true

  alias Mydia.Jobs.Broadcaster

  describe "topic/0" do
    test "returns the jobs status topic" do
      assert Broadcaster.topic() == "jobs:status"
    end
  end

  describe "subscribe/0" do
    test "subscribes the current process to job status updates" do
      assert :ok = Broadcaster.subscribe()

      # Verify subscription by checking we're subscribed to the topic
      # We'll broadcast and receive to verify
      Phoenix.PubSub.broadcast(Mydia.PubSub, "jobs:status", :test_message)
      assert_receive :test_message
    end
  end

  describe "attach/0 and detach/0" do
    test "attaches and detaches telemetry handlers" do
      # Detach first in case they're already attached from app startup
      Broadcaster.detach()

      # Attach handlers
      assert :ok = Broadcaster.attach()

      # Detach handlers
      assert :ok = Broadcaster.detach()
    end
  end

  describe "handle_event/4" do
    setup do
      # Subscribe to receive broadcast messages
      Broadcaster.subscribe()
      :ok
    end

    test "broadcasts status on job start event" do
      Broadcaster.handle_event([:oban, :job, :start], %{}, %{}, nil)

      # Should receive the jobs_status_changed message
      assert_receive {:jobs_status_changed, _jobs}
    end

    test "broadcasts status on job stop event" do
      Broadcaster.handle_event([:oban, :job, :stop], %{}, %{}, nil)

      assert_receive {:jobs_status_changed, _jobs}
    end

    test "broadcasts status on job exception event" do
      Broadcaster.handle_event([:oban, :job, :exception], %{}, %{}, nil)

      assert_receive {:jobs_status_changed, _jobs}
    end
  end

  describe "broadcast_status/0" do
    test "broadcasts current executing jobs to subscribers" do
      Broadcaster.subscribe()

      Broadcaster.broadcast_status()

      assert_receive {:jobs_status_changed, jobs}
      assert is_list(jobs)
    end
  end
end
