defmodule Mydia.WatchSync.IncrementalTest do
  use Mydia.DataCase, async: true

  import Mydia.MediaFixtures
  import Mydia.AccountsFixtures

  alias Mydia.WatchSync

  defmodule CountingProvider do
    @behaviour Mydia.WatchSync.Provider

    @impl true
    def refresh_mappings(instance, _opts) do
      Agent.update(instance.counter, &(&1 + 1))
      {:ok, instance.mappings}
    end

    @impl true
    def list_changes(instance, _scope, since) do
      send(instance.test_pid, {:since, since})
      {:ok, instance.changes}
    end

    @impl true
    def apply_change(_instance, _scope, _remote_id, _change), do: :ok
  end

  test "the full crawl runs once, not on every sync" do
    user = user_fixture()
    movie = media_item_fixture(%{tmdb_id: "12345"})
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    instance = %{
      id: "inst-1",
      test_pid: self(),
      counter: counter,
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
        %{remote_id: "rk1", watched: true, position_seconds: 0, at: DateTime.utc_now()}
      ]
    }

    scope = %{user_id: user.id, access_token: nil}

    {:ok, _} = WatchSync.sync(CountingProvider, instance, scope, provider: "counting")
    assert_received {:since, nil}

    {:ok, _} = WatchSync.sync(CountingProvider, instance, scope, provider: "counting")
    # The second run asks only for changes since the last sync, and does not
    # re-crawl the library.
    assert_received {:since, %DateTime{} = since}

    # The cursor deliberately trails the last write. synced_at is stamped when we
    # write, not when the remote event happened, so a view landing mid-run would
    # otherwise be skipped forever by a strictly-greater-than filter.
    assert DateTime.compare(since, DateTime.utc_now()) == :lt
    assert DateTime.diff(DateTime.utc_now(), since, :second) >= 60

    assert Agent.get(counter, & &1) == 1
    assert movie.id
  end

  test "refresh_mappings: :force re-crawls on demand" do
    user = user_fixture()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    instance = %{id: "i", test_pid: self(), counter: counter, mappings: [], changes: []}
    scope = %{user_id: user.id, access_token: nil}

    {:ok, _} = WatchSync.sync(CountingProvider, instance, scope, provider: "counting")

    {:ok, _} =
      WatchSync.sync(CountingProvider, instance, scope,
        provider: "counting",
        refresh_mappings: :force
      )

    assert Agent.get(counter, & &1) == 2
  end
end
