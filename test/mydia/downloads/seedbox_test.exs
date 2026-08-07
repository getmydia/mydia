defmodule Mydia.Downloads.SeedboxTest do
  use Mydia.DataCase, async: false

  alias Mydia.Downloads
  alias Mydia.Downloads.Download
  alias Mydia.Downloads.Seedbox
  alias Mydia.Downloads.Seedbox.Fetcher
  alias Mydia.Downloads.Structs.DownloadStatus
  alias Mydia.Repo

  setup do
    ensure_started!({Registry, keys: :unique, name: Mydia.Downloads.Seedbox.FetcherRegistry})

    ensure_started!(
      {DynamicSupervisor, name: Mydia.Downloads.Seedbox.FetcherSupervisor, strategy: :one_for_one}
    )

    :ok
  end

  defp ensure_started!(spec) do
    case start_supervised(spec) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp insert_download!(client_name, client_id, attrs \\ %{}) do
    %Download{}
    |> Download.changeset(
      Map.merge(
        %{
          title: "Release",
          download_client: client_name,
          download_client_id: client_id,
          metadata: %{}
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp client_config(overrides \\ %{}) do
    Map.merge(
      %{
        name: "seedbox-qbit",
        download_directory: "/tmp/downloads",
        connection_settings: %{
          "remote_fetch" => %{
            "enabled" => true,
            "host" => "127.0.0.1",
            "port" => 65_535,
            "username" => "u",
            "auth_method" => "password",
            "password" => "p"
          }
        }
      },
      overrides
    )
  end

  defp torrent(overrides \\ %{}) do
    struct!(
      DownloadStatus,
      Map.merge(
        %{
          id: "torrent-1",
          name: "Release",
          state: :downloading,
          progress: 50.0,
          size: 1000,
          downloaded: 500,
          download_speed: 0,
          upload_speed: 0,
          uploaded: 0,
          ratio: 0.0,
          save_path: "/remote/downloads/Release"
        },
        Map.new(overrides)
      )
    )
  end

  defp fake_running_fetcher!(download_id, client_name) do
    start_supervised!(%{
      id: {:fake_fetcher, download_id},
      start:
        {Agent, :start_link,
         [
           fn -> :ok end,
           [
             name:
               {:via, Registry,
                {Mydia.Downloads.Seedbox.FetcherRegistry, {:seedbox_fetcher, download_id},
                 client_name}}
           ]
         ]}
    })
  end

  test "returns torrents unchanged when remote_fetch is not enabled" do
    torrents = [torrent()]

    assert Seedbox.maybe_apply_remote_fetch(
             client_config(%{connection_settings: %{}}),
             torrents,
             %{}
           ) == torrents
  end

  test "returns the torrent unchanged when it isn't done yet on the remote client" do
    download = insert_download!("seedbox-qbit", "torrent-1")
    torrents = [torrent(state: :downloading)]

    [result] =
      Seedbox.maybe_apply_remote_fetch(client_config(), torrents, %{"torrent-1" => download})

    assert result.state == :downloading
  end

  test "claims a fetcher and reports :queued when the remote torrent just finished seeding" do
    download = insert_download!("seedbox-qbit", "torrent-1")
    torrents = [torrent(state: :seeding)]

    [result] =
      Seedbox.maybe_apply_remote_fetch(client_config(), torrents, %{"torrent-1" => download})

    assert result.state == :queued
    assert result.progress == 0.0
    assert {:ok, _pid} = Fetcher.whereis(download.id)
  end

  test "also claims a fetcher when the remote client reports :completed" do
    download = insert_download!("seedbox-qbit", "torrent-1")
    torrents = [torrent(state: :completed)]

    [result] =
      Seedbox.maybe_apply_remote_fetch(client_config(), torrents, %{"torrent-1" => download})

    assert result.state == :queued
    assert {:ok, _pid} = Fetcher.whereis(download.id)
  end

  test "reports :downloading with local bytes_pulled progress while the fetcher runs" do
    download = insert_download!("seedbox-qbit", "torrent-1")
    {:ok, download} = Downloads.History.update_download(download, %{bytes_pulled: 250})
    fake_running_fetcher!(download.id, "seedbox-qbit")

    torrents = [torrent(state: :seeding, size: 1000)]

    [result] =
      Seedbox.maybe_apply_remote_fetch(client_config(), torrents, %{"torrent-1" => download})

    assert result.state == :downloading
    assert result.downloaded == 250
    assert result.progress == 25.0
  end

  test "reports :error once the fetcher has failed terminally" do
    download = insert_download!("seedbox-qbit", "torrent-1")

    {:ok, download} =
      Downloads.History.update_download(download, %{import_failed_at: DateTime.utc_now()})

    torrents = [torrent(state: :seeding)]

    [result] =
      Seedbox.maybe_apply_remote_fetch(client_config(), torrents, %{"torrent-1" => download})

    assert result.state == :error
  end

  test "overrides save_path to the local path once the fetch has finished" do
    download =
      insert_download!("seedbox-qbit", "torrent-1", %{
        metadata: %{"save_path" => "/local/downloads/abc"}
      })

    torrents = [torrent(state: :seeding, save_path: "/remote/downloads/Release")]

    [result] =
      Seedbox.maybe_apply_remote_fetch(client_config(), torrents, %{"torrent-1" => download})

    assert result.save_path == "/local/downloads/abc"
    assert result.state == :seeding
  end

  test "does not claim a fetcher for a torrent with no matching local Download row" do
    torrents = [torrent(state: :seeding)]

    assert [result] = Seedbox.maybe_apply_remote_fetch(client_config(), torrents, %{})
    assert result.state == :seeding
  end

  test "respects max_concurrent_transfers and does not claim beyond the cap" do
    download_a = insert_download!("seedbox-qbit", "torrent-a")
    download_b = insert_download!("seedbox-qbit", "torrent-b")
    fake_running_fetcher!(download_a.id, "seedbox-qbit")

    torrents = [torrent(id: "torrent-b", state: :seeding)]

    config =
      client_config(%{
        connection_settings: %{
          "remote_fetch" =>
            client_config().connection_settings["remote_fetch"]
            |> Map.put("max_concurrent_transfers", 1)
        }
      })

    [result] = Seedbox.maybe_apply_remote_fetch(config, torrents, %{"torrent-b" => download_b})

    assert result.state == :queued
    assert Fetcher.whereis(download_b.id) == :error
  end
end
