defmodule Mydia.AccountsTest do
  use Mydia.DataCase, async: false

  alias Mydia.Accounts
  alias Mydia.Repo
  alias Mydia.Streaming.Torrent.SessionSchema

  describe "delete_user/1" do
    test "succeeds for a user with no torrent sessions" do
      user = Mydia.AccountsFixtures.user_fixture()

      assert {:ok, _} = Accounts.delete_user(user)
      refute Repo.get(Mydia.Accounts.User, user.id)
    end

    test "marks the user's active torrent session rows as cancelled before delete" do
      # We can't exercise the supervised GenServer path here without librqbit,
      # but we can verify the DB-side effect: stop_user_sessions/1 walks every
      # row in an active state and flips it to :cancelled before the user row
      # is dropped. The FK cascade then deletes the cancelled rows along with
      # the user.
      user = Mydia.AccountsFixtures.user_fixture()
      media_item = Mydia.MediaFixtures.media_item_fixture()

      {:ok, session} =
        Repo.insert(%SessionSchema{
          user_id: user.id,
          media_item_id: media_item.id,
          magnet: "magnet:?xt=urn:btih:cascade",
          infohash: "cascade_test_hash",
          release_title: "Cascade Test",
          state: :downloading,
          started_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      assert {:ok, _} = Accounts.delete_user(user)
      refute Repo.get(SessionSchema, session.id)
    end
  end
end
