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

  test "non_seeding_type?/1" do
    assert ClientRemoval.non_seeding_type?(:sabnzbd)
    assert ClientRemoval.non_seeding_type?(:nzbget)
    assert ClientRemoval.non_seeding_type?(:debrid)
    refute ClientRemoval.non_seeding_type?(:qbittorrent)
    refute ClientRemoval.non_seeding_type?(:transmission)
    refute ClientRemoval.non_seeding_type?(:rtorrent)
    refute ClientRemoval.non_seeding_type?(:rqbit)
    refute ClientRemoval.non_seeding_type?(:blackhole)
  end

  describe "import_consumes_source?/1" do
    test "is true for a download from a non-seeding client" do
      client = client!(type: :sabnzbd)
      download = download!(client, [])

      assert ClientRemoval.import_consumes_source?(download)
    end

    test "is false for a download from a torrent client" do
      client = client!(type: :qbittorrent)
      download = download!(client, [])

      refute ClientRemoval.import_consumes_source?(download)
    end

    test "is false when the client name matches no config" do
      download =
        download_fixture(%{
          download_client: "does-not-exist-#{System.unique_integer([:positive])}",
          download_client_id: "x"
        })

      refute ClientRemoval.import_consumes_source?(download)
    end

    test "is false when the download has no client" do
      download = download_fixture(%{download_client: nil, download_client_id: nil})

      refute ClientRemoval.import_consumes_source?(download)
    end
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

  test "finish_pending_removal leaves row pending when client config is missing" do
    download =
      download_fixture(%{
        download_client: "does-not-exist-#{System.unique_integer([:positive])}",
        download_client_id: "x",
        imported_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    assert :deferred = ClientRemoval.finish_pending_removal(download)
    assert is_nil(Downloads.get_download!(download.id).client_removed_at)
  end

  test "maybe_remove_after_import leaves row pending when client config is missing" do
    download =
      download_fixture(%{
        download_client: "does-not-exist-#{System.unique_integer([:positive])}",
        download_client_id: "x",
        imported_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    assert :deferred = ClientRemoval.maybe_remove_after_import(download)
    assert is_nil(Downloads.get_download!(download.id).client_removed_at)
  end

  test "list_pending_removals excludes unresolved_files downloads" do
    client = client!(type: :qbittorrent, remove_completed: true)
    unresolved = download!(client, imported: true, match_status: "unresolved_files")
    pending = download!(client, imported: true)

    ids = ClientRemoval.list_pending_removals() |> Enum.map(& &1.id)

    assert pending.id in ids
    refute unresolved.id in ids
  end

  test "list_pending_removals excludes downloads with an operator removal in flight" do
    client = client!(type: :qbittorrent, remove_completed: true)
    removing = download!(client, imported: true)

    {:ok, _} =
      Downloads.update_download(removing, %{
        removal_requested_at: DateTime.utc_now() |> DateTime.truncate(:second),
        removal_kind: "clear"
      })

    ids = ClientRemoval.list_pending_removals() |> Enum.map(& &1.id)

    refute removing.id in ids
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

  describe "seeding guard" do
    @private_ratio %{"private" => true, "minimum_ratio" => 1.0, "minimum_seed_time" => nil}

    test "terms_met?/2 truth table" do
      day = 86_400
      paused = fn ratio, time -> %{status(:paused, "x") | ratio: ratio, seeding_time: time} end

      with_terms = fn terms ->
        %Mydia.Downloads.Download{metadata: %{"tracker_terms" => terms}}
      end

      # No terms and not private: unchanged.
      assert ClientRemoval.terms_met?(%Mydia.Downloads.Download{metadata: %{}}, nil)

      ratio_only = with_terms.(%{"minimum_ratio" => 1.0})
      refute ClientRemoval.terms_met?(ratio_only, paused.(0.5, 10 * day))
      assert ClientRemoval.terms_met?(ratio_only, paused.(1.0, 0))

      time_only = with_terms.(%{"minimum_seed_time" => day})
      refute ClientRemoval.terms_met?(time_only, paused.(9.0, day - 1))
      assert ClientRemoval.terms_met?(time_only, paused.(0.0, day))

      both = with_terms.(%{"minimum_ratio" => 1.0, "minimum_seed_time" => day})
      refute ClientRemoval.terms_met?(both, paused.(0.5, 60))
      assert ClientRemoval.terms_met?(both, paused.(0.5, day))
      assert ClientRemoval.terms_met?(both, paused.(1.5, 60))

      private_no_terms = with_terms.(%{"private" => true})
      refute ClientRemoval.terms_met?(private_no_terms, paused.(99.0, 365 * day))
      refute ClientRemoval.terms_met?(private_no_terms, nil)
    end

    test "a guarded download stays pending on a seed-aware client even when paused" do
      client = client!(type: :qbittorrent, remove_completed: true)
      download = download!(client, terms: @private_ratio)
      StubAdapter.put(%{status(:paused, download.download_client_id) | ratio: 0.4})

      assert :still_seeding = ClientRemoval.maybe_remove_after_import(download)
      assert :still_seeding = ClientRemoval.finish_pending_removal(download)
      assert StubAdapter.take_removes() == []
      assert is_nil(Downloads.get_download!(download.id).client_removed_at)
      assert download.id in Enum.map(ClientRemoval.list_pending_removals(), & &1.id)
    end

    test "a download whose goal is met is removed once the client is idle" do
      client = client!(type: :qbittorrent, remove_completed: true)
      download = download!(client, terms: @private_ratio)
      StubAdapter.put(%{status(:paused, download.download_client_id) | ratio: 1.2})

      assert :removed = ClientRemoval.finish_pending_removal(download)
      assert [{_, [delete_files: true]}] = StubAdapter.take_removes()
    end

    test "a private download with no known ratio or seed time is never removed automatically" do
      client = client!(type: :qbittorrent, remove_completed: true)
      download = download!(client, terms: %{"private" => true})

      StubAdapter.put(%{
        status(:completed, download.download_client_id)
        | ratio: 50.0,
          seeding_time: 400 * 86_400
      })

      assert :still_seeding = ClientRemoval.maybe_remove_after_import(download)
      assert :still_seeding = ClientRemoval.finish_pending_removal(download)
      assert StubAdapter.take_removes() == []
    end

    test "a torrent that left the client is stamped removed even when guarded" do
      client = client!(type: :qbittorrent, remove_completed: true)
      download = download!(client, terms: @private_ratio)
      StubAdapter.put({:error, Error.not_found("gone")})

      assert :removed = ClientRemoval.finish_pending_removal(download)
      assert StubAdapter.take_removes() == []
    end

    test "rqbit waits for the goal, then removes without waiting for an idle state" do
      previous = Registry.lookup(:rqbit)
      Registry.register(:rqbit, StubAdapter)
      on_exit(fn -> if previous, do: Registry.register(:rqbit, previous) end)

      client = client!(type: :rqbit, remove_completed: true)
      download = download!(client, terms: %{"private" => true, "minimum_seed_time" => 3600})

      StubAdapter.put(%{status(:seeding, download.download_client_id) | seeding_time: 60})
      assert :still_seeding = ClientRemoval.maybe_remove_after_import(download)
      assert :still_seeding = ClientRemoval.finish_pending_removal(download)
      assert StubAdapter.take_removes() == []

      StubAdapter.put(%{status(:seeding, download.download_client_id) | seeding_time: 3600})
      assert :removed = ClientRemoval.finish_pending_removal(download)
      assert [{_, [delete_files: true]}] = StubAdapter.take_removes()
    end

    test "rqbit seeding time falls back to the download's completed_at" do
      previous = Registry.lookup(:rqbit)
      Registry.register(:rqbit, StubAdapter)
      on_exit(fn -> if previous, do: Registry.register(:rqbit, previous) end)

      client = client!(type: :rqbit, remove_completed: true)
      download = download!(client, terms: %{"minimum_seed_time" => 3600})

      {:ok, download} =
        Downloads.update_download(download, %{
          completed_at: DateTime.add(DateTime.utc_now(), -7200, :second)
        })

      StubAdapter.put(status(:seeding, download.download_client_id))
      assert :removed = ClientRemoval.finish_pending_removal(download)
    end

    test "blackhole keeps its pre-guard behaviour: removed as soon as it is complete" do
      previous = Registry.lookup(:blackhole)
      Registry.register(:blackhole, StubAdapter)
      on_exit(fn -> if previous, do: Registry.register(:blackhole, previous) end)

      client =
        client!(
          type: :blackhole,
          remove_completed: true,
          connection_settings: %{"watch_folder" => "/tmp/w", "completed_folder" => "/tmp/c"}
        )

      download = download!(client, terms: %{"private" => true, "minimum_seed_time" => 3600})
      StubAdapter.put(status(:completed, download.download_client_id))

      refute ClientRemoval.seeding_client_type?(:blackhole)
      assert :removed = ClientRemoval.finish_pending_removal(download)
      assert [{_, [delete_files: true]}] = StubAdapter.take_removes()
    end

    test "rTorrent stopped after seeding past its goal is removed on the time Mydia observed" do
      previous = Registry.lookup(:rtorrent)
      Registry.register(:rtorrent, StubAdapter)
      on_exit(fn -> if previous, do: Registry.register(:rtorrent, previous) end)

      client = client!(type: :rtorrent, remove_completed: true)
      download = download!(client, terms: %{"private" => true, "minimum_seed_time" => 3 * 86_400})
      StubAdapter.put(status(:completed, download.download_client_id))

      # Stopped, nothing observed: the seed time is unknown, so it stays.
      assert :still_seeding = ClientRemoval.finish_pending_removal(download)

      {:ok, observed} =
        Downloads.update_download(download, %{
          metadata:
            Map.put(download.metadata, "observed_seeding", %{
              "seconds" => 4 * 86_400,
              "last_seen_at" => nil
            })
        })

      assert :removed = ClientRemoval.finish_pending_removal(observed)
      assert [{_, [delete_files: true]}] = StubAdapter.take_removes()
    end

    test "a paused torrent that reports no seed time does not count paused time" do
      previous = Registry.lookup(:rqbit)
      Registry.register(:rqbit, StubAdapter)
      on_exit(fn -> if previous, do: Registry.register(:rqbit, previous) end)

      client = client!(type: :rqbit, remove_completed: true)
      download = download!(client, terms: %{"minimum_seed_time" => 3600})

      {:ok, download} =
        Downloads.update_download(download, %{
          completed_at: DateTime.add(DateTime.utc_now(), -30 * 86_400, :second)
        })

      StubAdapter.put(status(:paused, download.download_client_id))
      assert :still_seeding = ClientRemoval.finish_pending_removal(download)
      assert StubAdapter.take_removes() == []
    end
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

    attrs =
      case Keyword.get(opts, :terms) do
        nil -> attrs
        terms -> Map.put(attrs, :metadata, %{"tracker_terms" => terms})
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
