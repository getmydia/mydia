defmodule Mydia.Downloads.Queue.FilePreview do
  @moduledoc """
  A torrent's files and Mydia's automatic picks, listed before a manual grab
  so the operator can choose which files to download. Nothing is added to the
  client during a preview.

  `build/2` runs the first half of `ClientSelection.add_to_client/2`
  (`ClientSelection.prepare/2`), lists the files and runs
  `WantedFiles.select/2` on them. Confirming passes the preview back to the
  grab as `file_preview:` with the chosen `only_files:`; `confirm/2` then
  supplies the prepared input, client, listing and peers so the add fetches
  and lists nothing again.

  See `design/specs/2026-11-28-torrent-file-tree-design.md`, "Part 2".
  """

  alias Mydia.Downloads.Client
  alias Mydia.Downloads.Queue.{ClientSelection, Duplicates}
  alias Mydia.Downloads.Structs.TorrentFile
  alias Mydia.Downloads.WantedFiles
  alias Mydia.Indexers.SearchResult

  require Logger

  @enforce_keys [:search_result, :opts, :client_config, :adapter, :torrent_input_result]
  defstruct [
    :search_result,
    :opts,
    :client_config,
    :adapter,
    :torrent_input_result,
    :context,
    :auto,
    listed: [],
    peers: []
  ]

  @type t :: %__MODULE__{
          search_result: SearchResult.t(),
          opts: keyword(),
          client_config: map(),
          adapter: module(),
          torrent_input_result: term(),
          listed: [WantedFiles.file_map()],
          peers: [String.t()] | nil,
          context: WantedFiles.context() | nil,
          auto: WantedFiles.t() | nil
        }

  # What the add takes from the preview's prepared opts; everything else
  # (`:exclude_download_id`, `:manual`, ...) comes from the confirm.
  @prepared_keys [:download_type, :title, :content_type]

  @doc """
  Lists `search_result`'s files and computes the automatic picks.

  Refuses a duplicate (`:duplicate_download`, `:already_have_files`) before
  fetching anything, an NZB or a client without file selection as
  `:unsupported`, and an empty listing as `:no_files`. A failed listing
  returns the client's error.
  """
  @spec build(SearchResult.t(), keyword()) ::
          {:ok, t()}
          | {:error,
             :unsupported | :no_files | :duplicate_download | :already_have_files | term()}
  def build(%SearchResult{} = search_result, opts) do
    search_result = Duplicates.normalize_search_result_metadata(search_result)
    opts = Keyword.put(opts, :download_type, search_result.download_protocol)

    with :ok <- Duplicates.check_for_duplicate_download(search_result, opts),
         {:ok, prepared} <- ClientSelection.prepare(search_result, opts),
         :ok <- ensure_supported(prepared),
         {:ok, listed, peers} <- list(prepared) do
      {context, auto} = auto_select(search_result, opts, listed)

      {:ok,
       %__MODULE__{
         search_result: search_result,
         opts: prepared.opts,
         client_config: prepared.client_config,
         adapter: prepared.adapter,
         torrent_input_result: prepared.torrent_input_result,
         listed: listed,
         peers: peers,
         context: context,
         auto: auto
       }}
    end
  end

  @doc "The listed files, ticked where `auto_selected/1` picks them."
  @spec files(t()) :: [TorrentFile.t()]
  def files(%__MODULE__{listed: listed} = preview) do
    picks = auto_selected(preview)

    for %{index: index, path: path, length: length} <- listed do
      %TorrentFile{index: index, path: path, size: length, included?: index in picks}
    end
  end

  @doc """
  The indexes the automatic pass would download: its `only_files`, or every
  listed index when it kept everything (or could not decide).
  """
  @spec auto_selected(t()) :: MapSet.t(non_neg_integer())
  def auto_selected(%__MODULE__{auto: %WantedFiles{only_files: [_ | _] = only}}),
    do: MapSet.new(only)

  def auto_selected(%__MODULE__{listed: listed}), do: MapSet.new(listed, & &1.index)

  @doc false
  # For `ClientSelection.add_to_client/2`: the prepared fields and
  # `{selection, peers, listed}` for a confirmed choice of `opts[:only_files]`
  # (the automatic picks when absent). The confirm's opts win, except for the
  # download type, title and content type the preview resolved. A choice
  # without an importable video is refused before any client call.
  @spec confirm(t(), keyword()) ::
          {:ok, map(), {WantedFiles.t(), [String.t()] | nil, [WantedFiles.file_map()]}}
          | {:error, :no_importable_file}
  def confirm(%__MODULE__{} = preview, opts) do
    indexes = Keyword.get(opts, :only_files) || Enum.sort(auto_selected(preview))

    with {:ok, selection} <- WantedFiles.manual(preview.context, preview.listed, indexes) do
      add_opts =
        opts
        |> Keyword.drop([:file_preview, :only_files])
        |> Keyword.merge(Keyword.take(preview.opts, @prepared_keys))

      prepared = %{
        torrent_input_result: preview.torrent_input_result,
        download_type: Keyword.get(add_opts, :download_type),
        opts: add_opts,
        client_config: preview.client_config,
        adapter: preview.adapter
      }

      {:ok, prepared, {selection, preview.peers, preview.listed}}
    end
  end

  defp ensure_supported(%{torrent_input_result: {:file, _body, :nzb}}), do: {:error, :unsupported}
  defp ensure_supported(%{download_type: :nzb}), do: {:error, :unsupported}

  defp ensure_supported(%{adapter: adapter}) do
    if Client.supports_file_selection?(adapter), do: :ok, else: {:error, :unsupported}
  end

  defp list(prepared) do
    config = ClientSelection.config_to_map(prepared.client_config)
    input = ClientSelection.torrent_input(prepared.torrent_input_result)

    case Client.list_torrent_files(prepared.adapter, config, input) do
      {:ok, %{files: [_ | _] = files, peers: peers}} -> {:ok, files, peers}
      {:ok, %{files: []}} -> {:error, :no_files}
      {:error, _reason} = error -> error
    end
  end

  # Like the grab path's own selection: a failure only loses the automatic
  # picks (and the episode context), and the preview ticks every file instead.
  defp auto_select(search_result, opts, listed) do
    context = WantedFiles.context_for(search_result, opts)
    {context, WantedFiles.select(context, listed)}
  rescue
    error ->
      Logger.warning("File selection failed; ticking every file",
        title: search_result.title,
        error: Exception.message(error)
      )

      {nil, nil}
  end
end
