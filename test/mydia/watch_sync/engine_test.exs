defmodule Mydia.WatchSync.EngineTest do
  use Mydia.DataCase, async: true

  import Mydia.MediaFixtures
  import Mydia.AccountsFixtures

  import Ecto.Query

  alias Mydia.Accounts.Scope
  alias Mydia.Playback
  alias Mydia.WatchSync
  alias Mydia.WatchSync.{Mapping, State}

  defmodule StubProvider do
    @behaviour Mydia.WatchSync.Provider

    @impl true
    def refresh_mappings(instance, _opts), do: {:ok, instance.mappings}

    @impl true
    def list_changes(instance, _scope, _since), do: {:ok, instance.changes}

    @impl true
    def apply_change(instance, _scope, remote_id, change) do
      send(instance.test_pid, {:applied, remote_id, change})

      if remote_id in Map.get(instance, :fail_remote_ids, []),
        do: {:error, :unreachable},
        else: :ok
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

  describe "a movie with two copies on one server (#1079)" do
    test "every copy gets a mapping", %{user: user} do
      {:ok, _} = WatchSync.sync(StubProvider, two_copies([]), scope(user), provider: "stub")

      assert mapped_remote_ids("inst-copies") == ["rk-1080", "rk-4k"]
    end

    test "a watch on the copy crawled first is imported", %{user: user, movie: movie} do
      instance =
        two_copies([
          %{remote_id: "rk-4k", watched: true, position_seconds: 0, at: DateTime.utc_now()}
        ])

      {:ok, counts} = WatchSync.sync(StubProvider, instance, scope(user), provider: "stub")

      assert counts.not_found == 0
      assert counts.imported == 1
      assert %{watched: true} = Playback.get_progress(user.id, media_item_id: movie.id)
    end

    test "an unwatched copy does not unwatch a movie another copy has watched",
         %{user: user, movie: movie} do
      watched = %{remote_id: "rk-4k", watched: true, position_seconds: 0, at: DateTime.utc_now()}
      unwatched = %{remote_id: "rk-1080", watched: false, position_seconds: nil, at: nil}

      # The first sync imports the watch and records a watched snapshot.
      {:ok, _} =
        WatchSync.sync(StubProvider, two_copies([watched, unwatched]), scope(user),
          provider: "stub"
        )

      # A full listing reports the unwatched copy first.
      {:ok, counts} =
        WatchSync.sync(StubProvider, two_copies([unwatched, watched]), scope(user),
          provider: "stub"
        )

      assert counts.imported == 0
      assert counts.unchanged == 1
      assert %{watched: true} = Playback.get_progress(user.id, media_item_id: movie.id)
    end

    test "a partial listing does not unwatch a movie whose other copy was watched",
         %{user: user, movie: movie} do
      watched = %{
        remote_id: "rk-1080",
        watched: true,
        position_seconds: 0,
        at: DateTime.utc_now()
      }

      unwatched = %{remote_id: "rk-4k", watched: false, position_seconds: nil, at: nil}

      {:ok, _} =
        WatchSync.sync(StubProvider, two_copies([watched, unwatched]), scope(user),
          provider: "stub"
        )

      # An incremental run only lists the copy played since the cursor.
      partial = %{
        remote_id: "rk-4k",
        watched: false,
        position_seconds: 300,
        at: DateTime.utc_now()
      }

      {:ok, _} =
        WatchSync.sync(StubProvider, two_copies([partial]), scope(user), provider: "stub")

      assert %{watched: true} = Playback.get_progress(user.id, media_item_id: movie.id)
    end

    test "a local watch is pushed to every copy, including ones not in the changes",
         %{user: user, movie: movie} do
      {:ok, _} =
        Playback.save_progress(user.id, [media_item_id: movie.id], %{
          position_seconds: 100,
          duration_seconds: 100
        })

      instance =
        two_copies([
          %{remote_id: "rk-4k", watched: false, position_seconds: nil, at: DateTime.utc_now()}
        ])

      {:ok, counts} = WatchSync.sync(StubProvider, instance, scope(user), provider: "stub")

      assert counts.exported == 1
      assert_received {:applied, "rk-4k", %{watched: true}}
      assert_received {:applied, "rk-1080", %{watched: true}}
    end

    test "a push that fails on one copy records no snapshot", %{user: user, movie: movie} do
      {:ok, _} =
        Playback.save_progress(user.id, [media_item_id: movie.id], %{
          position_seconds: 100,
          duration_seconds: 100
        })

      instance =
        two_copies(
          [%{remote_id: "rk-4k", watched: false, position_seconds: nil, at: DateTime.utc_now()}],
          %{fail_remote_ids: ["rk-1080"]}
        )

      {:ok, counts} = WatchSync.sync(StubProvider, instance, scope(user), provider: "stub")

      assert counts.exported == 0
      assert Repo.get_by(State, user_id: user.id, media_item_id: movie.id) == nil
    end

    test "a forced crawl prunes copies the server no longer lists", %{user: user, movie: movie} do
      an_hour_ago = DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.truncate(:second)

      Repo.insert!(%Mapping{
        provider: "stub",
        provider_instance_id: "inst-copies",
        media_item_id: movie.id,
        remote_id: "rk-gone",
        last_seen_at: an_hour_ago
      })

      {:ok, _} =
        WatchSync.sync(StubProvider, two_copies([]), scope(user),
          provider: "stub",
          refresh_mappings: :force
        )

      assert mapped_remote_ids("inst-copies") == ["rk-1080", "rk-4k"]
    end

    test "an empty crawl prunes nothing", %{user: user, movie: movie} do
      an_hour_ago = DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.truncate(:second)

      Repo.insert!(%Mapping{
        provider: "stub",
        provider_instance_id: "inst-copies",
        media_item_id: movie.id,
        remote_id: "rk-4k",
        last_seen_at: an_hour_ago
      })

      {:ok, _} =
        WatchSync.sync(StubProvider, two_copies([], %{mappings: []}), scope(user),
          provider: "stub",
          refresh_mappings: :force
        )

      assert mapped_remote_ids("inst-copies") == ["rk-4k"]
    end
  end

  defp scope(user), do: %{user_id: user.id, access_token: nil}

  defp copy(remote_id) do
    %{
      remote_id: remote_id,
      type: :movie,
      external_ids: %{tmdb: "12345"},
      season_number: nil,
      episode_number: nil
    }
  end

  # The 4K copy is crawled first, so the old one-mapping-per-item upsert let the
  # 1080p copy overwrite it and every 4K watch came back as not_found.
  defp two_copies(changes, extra \\ %{}) do
    Map.merge(
      %{
        id: "inst-copies",
        test_pid: self(),
        mappings: [copy("rk-4k"), copy("rk-1080")],
        changes: changes
      },
      extra
    )
  end

  defp mapped_remote_ids(instance_id) do
    Mapping
    |> where([m], m.provider_instance_id == ^instance_id)
    |> select([m], m.remote_id)
    |> Repo.all()
    |> Enum.sort()
  end
end
