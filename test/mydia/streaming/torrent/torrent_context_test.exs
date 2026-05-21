defmodule Mydia.Streaming.TorrentContextTest do
  @moduledoc """
  Direct tests of the `Mydia.Streaming.Torrent` context functions that don't
  require booting the librqbit NIF. The Engine-dependent code paths (start_session
  end-to-end, add_torrent, read_chunk) are exercised via the integration
  test suite in player/integration_test/.
  """

  use Mydia.DataCase, async: false

  alias Mydia.Repo
  alias Mydia.Streaming.Torrent
  alias Mydia.Streaming.Torrent.SessionSchema

  describe "check_and_promote/1 atomic claim" do
    setup do
      user = Mydia.AccountsFixtures.user_fixture()
      media_item = Mydia.MediaFixtures.media_item_fixture()

      # Cross the playback threshold so the promote codepath is eligible.
      {:ok, _progress} =
        Mydia.Playback.save_progress(
          user.id,
          [media_item_id: media_item.id],
          %{position_seconds: 95, duration_seconds: 100}
        )

      {:ok, user: user, media_item: media_item}
    end

    test "two concurrent callers — only one wins the :promoting claim", %{
      user: user,
      media_item: media_item
    } do
      # Session is in :watching with download_progress < 1.0 so Promotion.promote
      # returns {:ok, :download_incomplete} on whichever caller wins the claim.
      # That's the simplest stable outcome to assert against — the test is about
      # the atomic claim itself, not Promotion's success path.
      {:ok, session} =
        Repo.insert(%SessionSchema{
          user_id: user.id,
          media_item_id: media_item.id,
          magnet: "magnet:?xt=urn:btih:concurrentclaim",
          infohash: "concurrent_claim_hash",
          release_title: "Concurrent Claim",
          state: :watching,
          download_progress: 0.5,
          started_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      # Without supervised session this would short-circuit at get_active_session.
      # Skip the supervisor lookup by reaching the claim directly via Repo.
      # The check_and_promote/1 function uses get_active_session which we can't
      # exercise without the supervisor; this test instead asserts the underlying
      # update_all returns the expected affected_count on race.
      query =
        Ecto.Query.from(s in SessionSchema,
          where: s.id == ^session.id and s.state in [:ready, :watching]
        )

      # Run two concurrent flips. Exactly one row should be updated.
      tasks = [
        Task.async(fn ->
          Repo.update_all(query, set: [state: :promoting])
        end),
        Task.async(fn ->
          Repo.update_all(query, set: [state: :promoting])
        end)
      ]

      [{count1, _}, {count2, _}] = Task.await_many(tasks)

      assert count1 + count2 == 1, "Expected exactly one promote-claim winner"

      reloaded = Repo.get!(SessionSchema, session.id)
      assert reloaded.state == :promoting
    end
  end

  describe "stop_user_sessions/1" do
    test "is a no-op for a user with no sessions" do
      user = Mydia.AccountsFixtures.user_fixture()
      assert :ok = Torrent.stop_user_sessions(user.id)
    end

    test "marks the user's sessions as :cancelled" do
      user = Mydia.AccountsFixtures.user_fixture()
      media_item = Mydia.MediaFixtures.media_item_fixture()

      {:ok, session} =
        Repo.insert(%SessionSchema{
          user_id: user.id,
          media_item_id: media_item.id,
          magnet: "magnet:?xt=urn:btih:stopuser",
          infohash: "stopuser_hash",
          release_title: "Stop User",
          state: :downloading,
          started_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      :ok = Torrent.stop_user_sessions(user.id)

      reloaded = Repo.get!(SessionSchema, session.id)
      assert reloaded.state == :cancelled
    end
  end

  describe "start_session/1 validation guards" do
    test "returns {:error, :streaming_disabled} when embedded streaming is off (default)" do
      # No streaming.embedded_enabled row in DB and runtime_config default
      # is false — this is the test env's baseline.
      user = Mydia.AccountsFixtures.user_fixture()
      media_item = Mydia.MediaFixtures.media_item_fixture()

      assert {:error, :streaming_disabled} =
               Torrent.start_session(%{
                 user_id: user.id,
                 media_item_id: media_item.id,
                 magnet: "magnet:?xt=urn:btih:disabled",
                 release_title: "Disabled Streaming",
                 state: :initializing
               })
    end

    test "returns {:error, :already_streaming, existing_id} when the infohash is already active" do
      # Flip the persisted toggle so we get past ensure_streaming_enabled and
      # into ensure_infohash_available. This is the actual guard under test.
      enable_embedded_streaming!()

      user = Mydia.AccountsFixtures.user_fixture()
      media_item = Mydia.MediaFixtures.media_item_fixture()
      infohash = "duplicateguardhash"

      {:ok, existing} =
        Repo.insert(%SessionSchema{
          user_id: user.id,
          media_item_id: media_item.id,
          magnet: "magnet:?xt=urn:btih:#{infohash}",
          infohash: infohash,
          release_title: "Already Streaming",
          state: :downloading,
          started_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      assert {:error, :already_streaming, existing_id} =
               Torrent.start_session(%{
                 user_id: user.id,
                 media_item_id: media_item.id,
                 magnet: "magnet:?xt=urn:btih:#{String.upcase(infohash)}",
                 release_title: "Duplicate Attempt",
                 state: :initializing
               })

      assert existing_id == existing.id

      # And the guard must have run *before* create_session_record/1 — no
      # extra SessionSchema row should have been written.
      assert Repo.aggregate(SessionSchema, :count, :id) == 1
    end

    test "non-active sessions with the same infohash don't trip the duplicate guard" do
      # A :completed session for the same hash represents an already-finished
      # promotion. The user should be allowed to start a fresh session — but
      # we can only assert this far without the NIF, so we stop at "guard
      # didn't fire". When the engine is wired the next step is the supervisor.
      enable_embedded_streaming!()

      user = Mydia.AccountsFixtures.user_fixture()
      media_item = Mydia.MediaFixtures.media_item_fixture()
      infohash = "completedguardhash"

      {:ok, _completed} =
        Repo.insert(%SessionSchema{
          user_id: user.id,
          media_item_id: media_item.id,
          magnet: "magnet:?xt=urn:btih:#{infohash}",
          infohash: infohash,
          release_title: "Already Finished",
          state: :completed,
          started_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      result =
        Torrent.start_session(%{
          user_id: user.id,
          media_item_id: media_item.id,
          magnet: "magnet:?xt=urn:btih:#{infohash}",
          release_title: "Retry After Completion",
          state: :initializing
        })

      # The :already_streaming guard must not fire. Anything past the guard
      # is fair game — on a host without the NIF the supervisor start may
      # error out, but it must not be the duplicate-guard error.
      refute match?({:error, :already_streaming, _}, result)
    end
  end

  defp enable_embedded_streaming! do
    attrs = %{
      "key" => "streaming.embedded_enabled",
      "value" => "true",
      "category" => "streaming"
    }

    case Mydia.Settings.get_config_setting_by_key("streaming.embedded_enabled") do
      nil -> Mydia.Settings.create_config_setting(attrs)
      setting -> Mydia.Settings.update_config_setting(setting, attrs)
    end

    :ok
  end
end
