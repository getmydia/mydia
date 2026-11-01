defmodule MydiaWeb.DownloadsLive.Retry do
  @moduledoc """
  The two ways the Downloads page retries a failed download: re-running its
  import, or grabbing the release again.

  Shared by the single-row and batch retry events in `DownloadsLive.Index`.
  """

  use Gettext, backend: MydiaWeb.Gettext

  alias Mydia.Downloads
  alias Mydia.Downloads.Structs.DownloadMetadata

  @doc """
  Clears the import failure and enqueues an immediate import.
  """
  @spec requeue_import(Mydia.Downloads.Download.t()) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  def requeue_import(download) do
    case Downloads.update_download(
           download,
           Mydia.Downloads.Download.cleared_import_failure_attrs()
         ) do
      {:ok, updated} ->
        %{
          "download_id" => updated.id,
          "save_path" => nil,
          "cleanup_client" => true,
          "use_hardlinks" => true
        }
        |> Mydia.Jobs.MediaImport.new()
        |> Oban.insert()

      error ->
        error
    end
  end

  @doc """
  Grabs the same release again: the old row is deleted and a new one is
  initiated from its download URL, against the same client when it had one.

  An imported download is never re-grabbed: a Retry button rendered before the
  import finished can still post its event, so this returns
  `{:error, :already_imported}` and leaves the row untouched.
  """
  @spec regrab(Mydia.Downloads.Download.t()) :: {:ok, term()} | {:error, term()}
  def regrab(%{imported_at: %DateTime{}}), do: {:error, :already_imported}

  def regrab(download) do
    metadata = DownloadMetadata.from_map(download.metadata)

    search_result = %Mydia.Indexers.SearchResult{
      download_url: download.download_url,
      title: download.title,
      indexer: download.indexer,
      size: metadata.size,
      seeders: metadata.seeders,
      leechers: metadata.leechers,
      quality: metadata.quality
    }

    opts =
      []
      |> maybe_add_opt(:media_item_id, download.media_item_id)
      |> maybe_add_opt(:episode_id, download.episode_id)
      |> maybe_add_opt(:client_name, download.download_client)

    Downloads.delete_download(download)
    Downloads.initiate_download(search_result, opts)
  end

  @doc "The flash text for a failed `regrab/1`."
  @spec regrab_error_message(term()) :: String.t()
  def regrab_error_message(:already_imported),
    do: gettext("That download was already imported")

  def regrab_error_message(reason),
    do: gettext("Failed to retry download: %{reason}", reason: inspect(reason))

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
