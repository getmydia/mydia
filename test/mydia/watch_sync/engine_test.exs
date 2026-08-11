defmodule Mydia.WatchSync.EngineTest do
  use Mydia.DataCase, async: true

  import Mydia.MediaFixtures
  import Mydia.AccountsFixtures

  alias Mydia.Playback
  alias Mydia.WatchSync

  defmodule StubProvider do
    @behaviour Mydia.WatchSync.Provider

    @impl true
    def refresh_mappings(instance, _opts), do: {:ok, instance.mappings}

    @impl true
    def list_changes(instance, _scope, _since), do: {:ok, instance.changes}

    @impl true
    def apply_change(instance, _scope, remote_id, change) do
      send(instance.test_pid, {:applied, remote_id, change})
      :ok
    end
  end

  setup do
    user = user_fixture()
    movie = media_item_fixture(%{tmdb_id: "12345"})
    {:ok, user: user, movie: movie}
  end

  test "a remote watch is imported locally", %{user: user, movie: movie} do
    instance = %{
      id: "inst-1",
      test_pid: self(),
      mappings: [
        %{
          remote_id: "rk1",
          type: :movie,
          external_ids: %{tmdb: "12345"},
          season_number: nil,
          episode_number: nil
        }
      ],
      changes: [%{remote_id: "rk1", watched: true, position_seconds: 0, at: DateTime.utc_now()}]
    }

    assert {:ok, counts} =
             WatchSync.sync(StubProvider, instance, %{user_id: user.id, access_token: nil},
               provider: "stub"
             )

    assert counts.imported == 1
    assert %{watched: true} = Playback.get_progress(user.id, media_item_id: movie.id)
  end

  test "a local unwatch is exported once a snapshot exists", %{user: user, movie: movie} do
    instance = %{
      id: "inst-1",
      test_pid: self(),
      mappings: [
        %{
          remote_id: "rk1",
          type: :movie,
          external_ids: %{tmdb: "12345"},
          season_number: nil,
          episode_number: nil
        }
      ],
      changes: [%{remote_id: "rk1", watched: true, position_seconds: 0, at: DateTime.utc_now()}]
    }

    scope = %{user_id: user.id, access_token: nil}

    # First sync establishes the snapshot on both sides.
    {:ok, _} = WatchSync.sync(StubProvider, instance, scope, provider: "stub")

    # The user then unwatches locally, which deletes the progress row.
    {:ok, _} = Playback.delete_progress(user.id, media_item_id: movie.id)

    {:ok, counts} = WatchSync.sync(StubProvider, instance, scope, provider: "stub")

    assert counts.exported == 1
    assert_received {:applied, "rk1", %{watched: false}}
  end

  test "an unmatched remote item is counted as not found", %{user: user} do
    instance = %{
      id: "inst-1",
      test_pid: self(),
      mappings: [
        %{
          remote_id: "rk9",
          type: :movie,
          external_ids: %{tmdb: "999999"},
          season_number: nil,
          episode_number: nil
        }
      ],
      changes: [%{remote_id: "rk9", watched: true, position_seconds: 0, at: DateTime.utc_now()}]
    }

    {:ok, counts} =
      WatchSync.sync(StubProvider, instance, %{user_id: user.id, access_token: nil},
        provider: "stub"
      )

    assert counts.not_found == 1
    assert counts.imported == 0
  end
end
