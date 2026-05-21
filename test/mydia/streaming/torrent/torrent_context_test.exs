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
end
