defmodule Mydia.Downloads.ClientRemovalTest do
  use Mydia.DataCase, async: false

  import Mydia.DownloadsFixtures

  alias Mydia.Downloads
  alias Mydia.Downloads.Client.Error
  alias Mydia.Downloads.Client.Registry
  alias Mydia.Downloads.ClientRemoval
  alias Mydia.Downloads.Structs.DownloadStatus
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

  test "seed_aware_type?/1" do
    assert ClientRemoval.seed_aware_type?(:qbittorrent)
    assert ClientRemoval.seed_aware_type?(:transmission)
    assert ClientRemoval.seed_aware_type?(:rtorrent)
    refute ClientRemoval.seed_aware_type?(:rqbit)
    refute ClientRemoval.seed_aware_type?(:sabnzbd)
    refute ClientRemoval.seed_aware_type?(:debrid)
  end

  test "removable_state?/1" do
    assert ClientRemoval.removable_state?(:paused)
    assert ClientRemoval.removable_state?(:completed)
    refute ClientRemoval.removable_state?(:seeding)
    refute ClientRemoval.removable_state?(:error)
    refute ClientRemoval.removable_state?(:downloading)
  end

  test "maybe_remove_after_import defers while seeding on seed-aware client" do
    client = client!(type: :qbittorrent, remove_completed: true)
    download = download!(client, imported: true)
    StubAdapter.put(status(:seeding, download.download_client_id))

    assert :deferred = ClientRemoval.maybe_remove_after_import(download)
    assert StubAdapter.take_removes() == []
    assert is_nil(Downloads.get_download!(download.id).client_removed_at)
  end

  test "maybe_remove_after_import defers on unexpected seed-aware states" do
    client = client!(type: :qbittorrent, remove_completed: true)
    download = download!(client, imported: true)
    StubAdapter.put(status(:unknown, download.download_client_id))

    assert :deferred = ClientRemoval.maybe_remove_after_import(download)
    assert StubAdapter.take_removes() == []
    assert is_nil(Downloads.get_download!(download.id).client_removed_at)
  end

  test "maybe_remove_after_import skips when remove_completed is false" do
    client = client!(type: :qbittorrent, remove_completed: false)
    download = download!(client, imported: true)
    StubAdapter.put(status(:paused, download.download_client_id))

    assert :skipped = ClientRemoval.maybe_remove_after_import(download)
    assert StubAdapter.take_removes() == []
    assert is_nil(Downloads.get_download!(download.id).client_removed_at)
  end

  test "maybe_remove_after_import removes immediately when paused" do
    client = client!(type: :qbittorrent, remove_completed: true)
    download = download!(client, imported: true)
    StubAdapter.put(status(:paused, download.download_client_id))

    assert :removed = ClientRemoval.maybe_remove_after_import(download)
    assert [{_, [delete_files: true]}] = StubAdapter.take_removes()
    assert %DateTime{} = Downloads.get_download!(download.id).client_removed_at
  end

  test "maybe_remove_after_import removes immediately for non-seed-aware types" do
    previous = Registry.lookup(:rqbit)
    Registry.register(:rqbit, StubAdapter)
    on_exit(fn -> if previous, do: Registry.register(:rqbit, previous) end)

    client = client!(type: :rqbit, remove_completed: true)
    download = download!(client, imported: true)
    StubAdapter.put(status(:seeding, download.download_client_id))

    assert :removed = ClientRemoval.maybe_remove_after_import(download)
    assert [{_, [delete_files: true]}] = StubAdapter.take_removes()
  end

  test "finish_pending_removal stamps on not_found without calling remove twice" do
    client = client!(type: :qbittorrent, remove_completed: true)
    download = download!(client, imported: true)
    StubAdapter.put({:error, Error.not_found("gone")})

    assert :removed = ClientRemoval.finish_pending_removal(download)
    assert StubAdapter.take_removes() == []
    assert %DateTime{} = Downloads.get_download!(download.id).client_removed_at
  end

  test "finish_pending_removal stamps when client config is missing" do
    download =
      download_fixture(%{
        download_client: "does-not-exist-#{System.unique_integer([:positive])}",
        download_client_id: "x",
        imported_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    assert :removed = ClientRemoval.finish_pending_removal(download)
    assert %DateTime{} = Downloads.get_download!(download.id).client_removed_at
  end

  test "list_pending_removals excludes unresolved_files downloads" do
    client = client!(type: :qbittorrent, remove_completed: true)
    unresolved = download!(client, imported: true, match_status: "unresolved_files")
    pending = download!(client, imported: true)

    ids = ClientRemoval.list_pending_removals() |> Enum.map(& &1.id)

    assert pending.id in ids
    refute unresolved.id in ids
  end

  test "finish_pending_removal removes non-seed-aware client immediately while seeding" do
    previous = Registry.lookup(:rqbit)
    Registry.register(:rqbit, StubAdapter)
    on_exit(fn -> if previous, do: Registry.register(:rqbit, previous) end)

    client = client!(type: :rqbit, remove_completed: true)
    download = download!(client, imported: true)
    StubAdapter.put(status(:seeding, download.download_client_id))

    assert :removed = ClientRemoval.finish_pending_removal(download)
    assert [{_, [delete_files: true]}] = StubAdapter.take_removes()
    assert %DateTime{} = Downloads.get_download!(download.id).client_removed_at
  end

  test "maybe_remove_after_import skips unresolved_files downloads" do
    client = client!(type: :qbittorrent, remove_completed: true)
    download = download!(client, imported: true, match_status: "unresolved_files")
    StubAdapter.put(status(:paused, download.download_client_id))

    assert :skipped = ClientRemoval.maybe_remove_after_import(download)
    assert StubAdapter.take_removes() == []
    assert is_nil(Downloads.get_download!(download.id).client_removed_at)
  end

  defp client!(opts) do
    unique = System.unique_integer([:positive])

    {:ok, client} =
      Settings.create_download_client_config(
        Enum.into(opts, %{
          name: "client-#{unique}",
          host: "localhost",
          port: 8080,
          enabled: true,
          priority: 1
        })
      )

    client
  end

  defp download!(client, opts) do
    imported = Keyword.get(opts, :imported, true)
    match_status = Keyword.get(opts, :match_status)

    attrs = %{
      download_client: client.name,
      download_client_id: "dl-#{System.unique_integer([:positive])}"
    }

    attrs =
      if imported do
        Map.put(attrs, :imported_at, DateTime.utc_now() |> DateTime.truncate(:second))
      else
        attrs
      end

    attrs =
      if match_status do
        Map.put(attrs, :match_status, match_status)
      else
        attrs
      end

    download_fixture(attrs)
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
