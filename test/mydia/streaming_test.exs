defmodule Mydia.StreamingTest do
  @moduledoc """
  Tests the top-level streaming context — primarily the new combined HLS +
  Torrent active-sessions listing introduced for the instant-streaming work.

  Deeper torrent behavior lives in `Mydia.Streaming.Torrent.*Test`; this file
  covers the cross-mode aggregator only.
  """

  use Mydia.DataCase, async: false

  alias Mydia.Streaming
  alias Mydia.Streaming.Torrent.SessionSchema

  describe "list_active_sessions/0" do
    test "returns a list (empty when nothing is running)" do
      assert is_list(Streaming.list_active_sessions())
    end

    test "ignores torrent session rows that aren't tracked by the supervisor" do
      # Inserting a row directly should NOT make it appear in the active list,
      # because the live view is driven by the supervised process registry —
      # not just by DB rows. This protects against showing zombie sessions
      # after a crash/restart.
      user = Mydia.AccountsFixtures.user_fixture()
      media_item = Mydia.MediaFixtures.media_item_fixture()

      {:ok, _row} =
        Mydia.Repo.insert(%SessionSchema{
          user_id: user.id,
          media_item_id: media_item.id,
          magnet: "magnet:?xt=urn:btih:notsupervised",
          infohash: "not_supervised_hash",
          release_title: "Orphan Row",
          state: :downloading,
          started_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      assert Enum.all?(
               Streaming.list_active_sessions(),
               &(&1.session_id != "not_supervised_hash")
             )
    end
  end
end
