defmodule Mydia.Jobs.DownloadMonitorClientRemovalTest do
  @moduledoc """
  DownloadMonitor poll pass for deferred Remove After Import cleanup.

  `async: false`: the adapter registry is a process-wide Agent.
  """
  use Mydia.DataCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  import Mydia.DownloadsFixtures

  alias Mydia.Downloads
  alias Mydia.Downloads.Client.Error
  alias Mydia.Downloads.Client.Registry
  alias Mydia.Downloads.ClientRemoval
  alias Mydia.Downloads.Structs.DownloadStatus
  alias Mydia.Jobs.DownloadMonitor
  alias Mydia.Settings

  defmodule StubAdapter do
    @behaviour Mydia.Downloads.Client

    def put(status_or_error), do: :persistent_term.put({__MODULE__, :result}, status_or_error)
    def take_removes, do: :persistent_term.get({__MODULE__, :removes}, [])

    @impl true
    def get_status(_config, _id) do
      case :persistent_term.get({__MODULE__, :result}, nil) do
        {:error, _} = err -> err
        %DownloadStatus{} = s -> {:ok, s}
        nil -> {:error, Error.not_found("missing")}
      end
    end

    @impl true
    def remove_torrent(_config, id, opts) do
      list = :persistent_term.get({__MODULE__, :removes}, [])
      :persistent_term.put({__MODULE__, :removes}, [{id, opts} | list])
      :ok
    end

    @impl true
    def test_connection(_), do: {:error, :not_implemented}
    @impl true
    def add_torrent(_, _, _), do: {:error, :not_implemented}
    @impl true
    def list_torrents(_, _), do: {:ok, []}
    @impl true
    def pause_torrent(_, _), do: :ok
    @impl true
    def resume_torrent(_, _), do: :ok
    @impl true
    def supported_protocols, do: [:torrent]
  end

  setup do
    previous = Registry.lookup(:qbittorrent)
    Registry.register(:qbittorrent, StubAdapter)
    :persistent_term.put({StubAdapter, :removes}, [])

    on_exit(fn ->
      :persistent_term.erase({StubAdapter, :result})
      :persistent_term.erase({StubAdapter, :removes})
      if previous, do: Registry.register(:qbittorrent, previous)
    end)

    :ok
  end

  test "finishes deferred removal when torrent is paused" do
    client = client!(remove_completed: true)
    download = pending_download!(client)
    StubAdapter.put(status(:paused, download.download_client_id))

    assert [pending] = ClientRemoval.list_pending_removals()
    assert pending.id == download.id

    assert :ok = perform_job(DownloadMonitor, %{})

    assert [{_, [delete_files: true]}] = StubAdapter.take_removes()
    assert %DateTime{} = Downloads.get_download!(download.id).client_removed_at
  end

  test "leaves pending removal while torrent is still seeding" do
    client = client!(remove_completed: true)
    download = pending_download!(client)
    StubAdapter.put(status(:seeding, download.download_client_id))

    assert :ok = perform_job(DownloadMonitor, %{})

    assert StubAdapter.take_removes() == []
    assert is_nil(Downloads.get_download!(download.id).client_removed_at)
  end

  test "stamps pending removal when torrent is not found in client" do
    client = client!(remove_completed: true)
    download = pending_download!(client)
    StubAdapter.put({:error, Error.not_found("gone")})

    assert :ok = perform_job(DownloadMonitor, %{})

    assert StubAdapter.take_removes() == []
    assert %DateTime{} = Downloads.get_download!(download.id).client_removed_at
  end

  defp client!(opts) do
    unique = System.unique_integer([:positive])

    {:ok, client} =
      Settings.create_download_client_config(
        Enum.into(opts, %{
          name: "client-#{unique}",
          type: :qbittorrent,
          host: "localhost",
          port: 8080,
          enabled: true,
          priority: 1,
          remove_completed: true
        })
      )

    client
  end

  defp pending_download!(client) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    download_fixture(%{
      download_client: client.name,
      download_client_id: "dl-#{System.unique_integer([:positive])}",
      completed_at: now,
      imported_at: now,
      client_removed_at: nil
    })
  end

  defp status(state, client_id) do
    DownloadStatus.new(%{
      id: client_id,
      name: "test",
      state: state,
      progress: 100.0
    })
  end
end
