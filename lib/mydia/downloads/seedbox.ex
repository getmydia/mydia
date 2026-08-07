defmodule Mydia.Downloads.Seedbox do
  @moduledoc """
  Intercepts a remote torrent client's raw status for configs with
  `connection_settings["remote_fetch"]["enabled"]` set, claiming a
  `Seedbox.Fetcher` when the remote side finishes and holding the download at
  an existing `DownloadStatus` state (`:queued`/`:downloading`/`:error`) until
  the local SFTP pull completes. Mirrors `Debrid.Shared.synthesize_status/3`.

  Torrent-client adapters report a finished-but-seeding torrent as
  `:seeding`, not `:completed` (confirmed for qBittorrent's `parse_state/1`)
  — both are treated as "remote side is done" here, matching
  `DownloadMonitor`'s own completion filter.
  """

  alias Mydia.Downloads.Download
  alias Mydia.Downloads.Seedbox.Fetcher
  alias Mydia.Downloads.Structs.DownloadStatus

  @remote_done_states [:completed, :seeding]

  @doc """
  Applies remote-fetch interception to every torrent reported by a client
  config, when that config has `remote_fetch` enabled. `client_downloads` is
  keyed by `download_client_id`, the same map `History.fetch_all_client_statuses/2`
  already builds for every adapter. Returns `torrents` unchanged for configs
  without `remote_fetch` enabled, or for torrents with no matching local
  `Download` row yet (nothing to intercept until Mydia has grabbed it).
  """
  @spec maybe_apply_remote_fetch(map(), [DownloadStatus.t()], %{String.t() => Download.t()}) ::
          [DownloadStatus.t()]
  def maybe_apply_remote_fetch(client_config, torrents, client_downloads) do
    case remote_fetch_config(client_config) do
      nil ->
        torrents

      remote_fetch ->
        client_name = Map.fetch!(client_config, :name)
        download_directory = Map.get(client_config, :download_directory)

        Enum.map(torrents, fn torrent ->
          case Map.get(client_downloads, torrent.id) do
            nil ->
              torrent

            download ->
              apply_torrent(torrent, download, remote_fetch, client_name, download_directory)
          end
        end)
    end
  end

  defp remote_fetch_config(client_config) do
    case Map.get(client_config, :connection_settings) do
      %{"remote_fetch" => %{"enabled" => true} = remote_fetch} -> remote_fetch
      _ -> nil
    end
  end

  defp apply_torrent(torrent, download, remote_fetch, client_name, download_directory) do
    local_save_path = get_in(download.metadata || %{}, ["save_path"])

    cond do
      is_binary(local_save_path) and local_save_path != "" ->
        # Local pull already finished — MediaImport must read the LOCAL
        # copy, not the remote client's own reported path.
        %{torrent | save_path: local_save_path}

      torrent.state not in @remote_done_states ->
        # Remote torrent still downloading/paused/etc on the seedbox side —
        # nothing to intercept, surface the client's own status untouched.
        torrent

      not is_nil(download.import_failed_at) ->
        %{torrent | state: :error}

      match?({:ok, _}, Fetcher.whereis(download.id)) ->
        bytes = download.bytes_pulled || 0
        progress = if torrent.size > 0, do: bytes / torrent.size * 100.0, else: 0.0
        %{torrent | state: :downloading, downloaded: bytes, progress: progress}

      true ->
        maybe_claim(
          download,
          remote_path(torrent, remote_fetch),
          remote_fetch,
          client_name,
          download_directory
        )

        %{torrent | state: :queued, progress: 0.0, downloaded: 0}
    end
  end

  defp maybe_claim(download, remote_path, remote_fetch, client_name, download_directory) do
    max_concurrent = Map.get(remote_fetch, "max_concurrent_transfers", 2)

    if Fetcher.count_running(client_name) < max_concurrent do
      Fetcher.claim(
        download_id: download.id,
        client_name: client_name,
        remote_fetch: remote_fetch,
        remote_path: remote_path,
        download_directory: download_directory
      )
    else
      :ok
    end
  end

  # The torrent client's own reported save_path is on the SAME host the SFTP
  # connection targets — see the design's "Path resolution" decision.
  # `remote_path_prefix` rewrites it for the rare case the SFTP root differs
  # from the torrent client's own filesystem view (e.g. a chrooted SFTP jail).
  defp remote_path(torrent, %{"remote_path_prefix" => prefix})
       when is_binary(prefix) and prefix != "" do
    String.replace_prefix(torrent.save_path, prefix, "")
  end

  defp remote_path(torrent, _remote_fetch), do: torrent.save_path
end
