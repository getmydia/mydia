defmodule Mydia.Jobs.RemoveDownloadTest do
  # Not async: one test swaps an adapter in the global client registry.
  use Mydia.DataCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  import Mydia.DownloadsFixtures
  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Downloads.Client.Error
  alias Mydia.Downloads.Client.Registry
  alias Mydia.Downloads.Download
  alias Mydia.Jobs.RemoveDownload
  alias Mydia.Repo

  @hash "0123456789abcdef0123456789abcdef01234567"

  defmodule NotFoundAdapter do
    @behaviour Mydia.Downloads.Client

    @impl true
    def supported_protocols, do: [:torrent]
    @impl true
    def test_connection(_config), do: {:error, :not_implemented}
    @impl true
    def add_torrent(_config, _torrent, _opts), do: {:error, :not_implemented}
    @impl true
    def get_status(_config, _client_id), do: {:error, Error.not_found("gone")}
    @impl true
    def list_torrents(_config, _opts), do: {:ok, []}
    @impl true
    def pause_torrent(_config, _client_id), do: :ok
    @impl true
    def resume_torrent(_config, _client_id), do: :ok
    @impl true
    def remove_torrent(_config, _client_id, _opts), do: {:error, Error.not_found("gone")}
  end

  defp pending(attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    download_fixture(
      Map.merge(
        %{removal_requested_at: now, removal_kind: "cancel", removal_delete_files: true},
        attrs
      )
    )
  end

  # A Transmission RPC endpoint. `reply` gets the decoded request body and
  # returns the response payload.
  defp transmission_client(reply) do
    bypass = Bypass.open()

    client =
      download_client_config_fixture(%{
        type: "transmission",
        host: "localhost",
        port: bypass.port
      })

    Bypass.stub(bypass, "POST", "/transmission/rpc", fn conn ->
      case Plug.Conn.get_req_header(conn, "x-transmission-session-id") do
        [] ->
          conn
          |> Plug.Conn.put_resp_header("x-transmission-session-id", "test-session")
          |> Plug.Conn.resp(409, "")

        _session ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, Jason.encode!(reply.(Jason.decode!(body))))
      end
    end)

    client
  end

  test "removes the torrent with the requested delete flag, then deletes the row" do
    test_pid = self()

    client =
      transmission_client(fn rpc ->
        send(test_pid, {:rpc, rpc["method"], rpc["arguments"]})
        %{"result" => "success", "arguments" => %{}}
      end)

    download = pending(%{download_client: client.name, download_client_id: @hash})

    assert :ok = perform_job(RemoveDownload, %{"download_id" => download.id})

    assert_received {:rpc, "torrent-remove", %{"delete-local-data" => true}}
    refute Repo.get(Download, download.id)
  end

  test "a client error before the last attempt is returned and the row stays pending" do
    client = transmission_client(fn _rpc -> %{"result" => "disk is read-only"} end)
    download = pending(%{download_client: client.name, download_client_id: @hash})

    assert {:error, _reason} =
             perform_job(RemoveDownload, %{"download_id" => download.id}, attempt: 1)

    row = Repo.get!(Download, download.id)
    assert %DateTime{} = row.removal_requested_at
    assert is_nil(row.removal_error)
  end

  test "a client error on the last attempt is recorded on the row" do
    client = transmission_client(fn _rpc -> %{"result" => "disk is read-only"} end)
    download = pending(%{download_client: client.name, download_client_id: @hash})

    assert :ok = perform_job(RemoveDownload, %{"download_id" => download.id}, attempt: 5)

    row = Repo.get!(Download, download.id)
    assert is_nil(row.removal_requested_at)
    assert row.removal_error == "Failed to remove torrent"
  end

  test "a not-found answer counts as removed" do
    previous = Registry.lookup(:rqbit)
    Registry.register(:rqbit, NotFoundAdapter)
    on_exit(fn -> if previous, do: Registry.register(:rqbit, previous) end)

    client = download_client_config_fixture(%{type: "rqbit"})
    download = pending(%{download_client: client.name, download_client_id: "rqbit-1"})

    assert :ok = perform_job(RemoveDownload, %{"download_id" => download.id})
    refute Repo.get(Download, download.id)
  end

  test "a download whose client is not configured is deleted without a client call" do
    download = pending(%{download_client: "fictional-missing-client", download_client_id: "x"})

    assert :ok = perform_job(RemoveDownload, %{"download_id" => download.id})
    refute Repo.get(Download, download.id)
  end

  test "a reject queues the replacement search once the row is gone" do
    media_item = media_item_fixture(%{type: "movie"})

    download =
      pending(%{
        media_item_id: media_item.id,
        download_client: "fictional-missing-client",
        removal_kind: "reject"
      })

    assert :ok = perform_job(RemoveDownload, %{"download_id" => download.id})

    refute Repo.get(Download, download.id)

    assert_enqueued(
      worker: Mydia.Jobs.MovieSearch,
      args: %{"mode" => "specific", "media_item_id" => media_item.id}
    )
  end

  if Mydia.Repo.__adapter__() == Ecto.Adapters.SQLite3 do
    test "a replacement enqueue failure keeps the reject pending for retry" do
      media_item = media_item_fixture(%{type: "movie"})

      download =
        pending(%{
          media_item_id: media_item.id,
          download_client: "fictional-missing-client",
          removal_kind: "reject"
        })

      Repo.query!("""
      CREATE TEMP TRIGGER fail_replacement_enqueue
      BEFORE INSERT ON oban_jobs
      WHEN NEW.worker = 'Mydia.Jobs.MovieSearch'
      BEGIN
        SELECT RAISE(ABORT, 'forced replacement enqueue failure');
      END
      """)

      on_exit(fn -> Repo.query!("DROP TRIGGER IF EXISTS fail_replacement_enqueue") end)

      assert {:error, _reason} =
               perform_job(RemoveDownload, %{"download_id" => download.id}, attempt: 1)

      row = Repo.get!(Download, download.id)
      assert %DateTime{} = row.removal_requested_at
      assert row.removal_kind == "reject"
      refute_enqueued(worker: Mydia.Jobs.MovieSearch)
    end

    test "a replacement search is inserted only after the rejected row is deleted" do
      media_item = media_item_fixture(%{type: "movie"})

      download =
        pending(%{
          media_item_id: media_item.id,
          download_client: "fictional-missing-client",
          removal_kind: "reject"
        })

      Repo.query!("""
      CREATE TEMP TRIGGER require_reject_deleted
      BEFORE INSERT ON oban_jobs
      WHEN NEW.worker = 'Mydia.Jobs.MovieSearch'
        AND EXISTS (SELECT 1 FROM downloads WHERE id = '#{download.id}')
      BEGIN
        SELECT RAISE(ABORT, 'replacement search was inserted before deletion');
      END
      """)

      on_exit(fn -> Repo.query!("DROP TRIGGER IF EXISTS require_reject_deleted") end)

      assert :ok = perform_job(RemoveDownload, %{"download_id" => download.id})
      refute Repo.get(Download, download.id)

      assert_enqueued(
        worker: Mydia.Jobs.MovieSearch,
        args: %{"mode" => "specific", "media_item_id" => media_item.id}
      )
    end
  end

  test "a row that is not pending is left alone" do
    download = download_fixture(%{download_client: "fictional-missing-client"})

    assert :ok = perform_job(RemoveDownload, %{"download_id" => download.id})
    assert Repo.get(Download, download.id)
  end

  test "a row that is already gone is a no-op" do
    assert :ok = perform_job(RemoveDownload, %{"download_id" => Ecto.UUID.generate()})
  end
end
