defmodule Mydia.Accounts.RevokeStaleAccessTest do
  # Drives the real session registry and real DirectPlaySessions, so the
  # sandbox has to be shared with those processes.
  use Mydia.DataCase, async: false

  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Accounts
  alias Mydia.Streaming.HlsSessionSupervisor

  defp direct_play(media_file, user) do
    {:ok, pid, :started} = HlsSessionSupervisor.start_direct_session(media_file.id, user.id)
    on_exit(fn -> HlsSessionSupervisor.stop_direct_session(media_file.id, user.id) end)
    pid
  end

  defp file_in(category) do
    item = categorized_media_item_fixture(%{type: "movie"}, category)
    media_file_fixture(%{media_item_id: item.id})
  end

  test "adding a restriction stops sessions on newly hidden files only" do
    user = user_fixture()
    hidden = direct_play(file_in("movie"), user)
    kept = direct_play(file_in("cartoon_movie"), user)
    ref = Process.monitor(hidden)

    {:ok, _} = Accounts.upsert_access_restriction(user, %{allowed_categories: ["cartoon_movie"]})

    assert_receive {:DOWN, ^ref, :process, _, _}, 1_000
    assert Process.alive?(kept)
  end

  test "clearing a restriction stops nothing" do
    user = restricted_user_fixture(%{allowed_categories: ["cartoon_movie"]})
    pid = direct_play(file_in("cartoon_movie"), user)

    :ok = Accounts.clear_access_restriction(user)

    assert Process.alive?(pid)
  end

  test "another user's sessions are untouched" do
    user = user_fixture()
    other = user_fixture()
    pid = direct_play(file_in("movie"), other)

    {:ok, _} = Accounts.upsert_access_restriction(user, %{allowed_categories: ["cartoon_movie"]})

    assert Process.alive?(pid)
  end
end
