defmodule Mydia.WatchSync.EngineTest do
  use Mydia.DataCase, async: true

  import Mydia.MediaFixtures
  import Mydia.AccountsFixtures

  alias Mydia.Accounts.Scope
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

  describe "direction" do
    setup %{movie: movie} do
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

      {:ok, instance: instance, movie: movie}
    end

    test "export-only does not write remote state into Mydia",
         %{user: user, movie: movie, instance: instance} do
      scope = %{user_id: user.id, access_token: nil}

      {:ok, counts} =
        WatchSync.sync(StubProvider, instance, scope, provider: "stub", direction: :export)

      # The operator chose export-only, so a remote watch must not be imported.
      assert counts.imported == 0
      assert counts.skipped_by_direction == 1
      assert Playback.get_progress(user.id, media_item_id: movie.id) == nil
    end

    test "import-only does not push local state to the remote", %{user: user, movie: movie} do
      {:ok, _} =
        Playback.save_progress(user.id, [media_item_id: movie.id], %{
          position_seconds: 100,
          duration_seconds: 100
        })

      instance = %{
        id: "inst-2",
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
        changes: [
          %{remote_id: "rk1", watched: false, position_seconds: nil, at: DateTime.utc_now()}
        ]
      }

      scope = %{user_id: user.id, access_token: nil}

      {:ok, counts} =
        WatchSync.sync(StubProvider, instance, scope, provider: "stub", direction: :import)

      assert counts.exported == 0
      refute_received {:applied, _, _}
    end
  end

  test "an episode maps when its show carries no local imdb id" do
    user = user_fixture()

    {:ok, show} =
      Mydia.Media.create_media_item(
        Scope.unrestricted(),
        %{title: "Tvdb Only Show", type: "tv_show", tvdb_id: 378_982},
        skip_episode_refresh: true
      )

    {:ok, episode} =
      Mydia.Media.create_episode(%{
        media_item_id: show.id,
        season_number: 1,
        episode_number: 1,
        title: "Pilot"
      })

    instance = %{
      id: "inst-ep",
      test_pid: self(),
      mappings: [
        %{
          remote_id: "ep1",
          type: :episode,
          # Exactly what Plex returns: all three ids on the show, none of them
          # imdb-resolvable locally.
          external_ids: %{imdb: "tt10590066", tmdb: "108255", tvdb: "378982"},
          season_number: 1,
          episode_number: 1
        }
      ],
      changes: [%{remote_id: "ep1", watched: true, position_seconds: 0, at: DateTime.utc_now()}]
    }

    assert {:ok, counts} =
             WatchSync.sync(StubProvider, instance, %{user_id: user.id, access_token: nil},
               provider: "stub"
             )

    assert counts.not_found == 0
    assert counts.imported == 1
    assert %{watched: true} = Playback.get_progress(user.id, episode_id: episode.id)
  end
end
