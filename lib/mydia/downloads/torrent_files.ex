defmodule Mydia.Downloads.TorrentFiles do
  @moduledoc """
  The operator's manual choice of which files a client downloads for a torrent,
  until the download is imported.

  A saved choice is stamped as `"file_selection" => %{"source" => "manual"}` so
  the automatic `BuiltIn.FileSelectionPolicy` never overrides it.
  """

  alias Mydia.Downloads.{Client, FileSelection, MetadataKey, Queue}
  alias Mydia.Downloads.Structs.TorrentFile

  @key "file_selection"

  @doc "True when the download's client can select files and the download has a client id."
  @spec supported?(map()) :: boolean()
  def supported?(%{download_client_id: id, download_client: name})
      when is_binary(id) and id != "" and is_binary(name) do
    case Queue.resolve_adapter(name) do
      {:ok, adapter, _config} -> Client.supports_file_selection?(adapter)
      _ -> false
    end
  end

  def supported?(_download), do: false

  @doc "True until the download has been imported."
  @spec editable?(map()) :: boolean()
  def editable?(download), do: is_nil(download.imported_at)

  @doc "The torrent's files as the client reports them."
  @spec list(map()) :: {:ok, [TorrentFile.t()]} | {:error, term()}
  def list(download) do
    with {:ok, adapter, config} <- Queue.resolve_adapter(download.download_client) do
      Client.torrent_files(adapter, config, download.download_client_id)
    end
  end

  @doc """
  Applies `indexes` as the files to download. Refuses an imported download and
  a selection without any importable file.
  """
  @spec save(map(), [non_neg_integer()]) ::
          :ok | {:error, :imported | :no_importable_file | term()}
  def save(download, indexes) when is_list(indexes) do
    with :ok <- check_editable(download),
         {:ok, adapter, config} <- Queue.resolve_adapter(download.download_client),
         {:ok, files} <- Client.torrent_files(adapter, config, download.download_client_id),
         :ok <- check_importable(files, indexes),
         :ok <- Client.set_file_selection(adapter, config, download.download_client_id, indexes) do
      MetadataKey.put(download.id, @key, %{"source" => "manual"})
    end
  end

  defp check_editable(download),
    do: if(editable?(download), do: :ok, else: {:error, :imported})

  defp check_importable(files, indexes) do
    selected = MapSet.new(indexes)

    if Enum.any?(files, &(&1.index in selected and FileSelection.importable?(&1.path))),
      do: :ok,
      else: {:error, :no_importable_file}
  end
end
