defmodule Mydia.Downloads.Grabber do
  @moduledoc """
  Optimistic manual-grab pipeline.

  `grab_async/2` inserts the `Download` record immediately — with no
  `download_client`/`download_client_id`, which derives to the `"grabbing"`
  status — and runs the slow work (duplicate check, torrent fetch, client
  handoff) in a task supervised by `Mydia.Downloads.GrabSupervisor`, so the
  grab survives the caller's death (modal close, navigation).

  Outcomes are broadcast on the `"downloads"` PubSub topic:

    * `{:grab_completed, %{download_id: id, download_url: url}}`
    * `{:grab_failed, %{download_id: id, download_url: url, reason: reason}}`
    * `{:grab_duplicate, %{download_url: url, reason: reason}}`

  The duplicate `reason` is `:duplicate_download` when a download is already in
  flight, or `:already_have_files` when the files are already on disk.

  A duplicate is benign: the optimistic record is deleted rather than failed.
  So is a task that never starts: the record is deleted and the caller gets
  `{:error, {:task_start_failed, reason}}` rather than a `MatchError`.

  `grab_async/2` accepts a `:supervisor` option so tests can point the task at
  a supervisor they control; it defaults to `Mydia.Downloads.GrabSupervisor`.
  """

  import Ecto.Query, warn: false

  alias Mydia.Downloads.Download
  alias Mydia.Downloads.History
  alias Mydia.Downloads.Queue
  alias Mydia.Events
  alias Mydia.Indexers.SearchResult
  alias Mydia.Repo
  alias Phoenix.PubSub

  require Logger

  @supervisor Mydia.Downloads.GrabSupervisor
  @topic "downloads"
  @max_error_length 500

  @spec grab_async(SearchResult.t(), keyword()) ::
          {:ok, Download.t()} | {:error, Ecto.Changeset.t() | {:task_start_failed, term()}}
  def grab_async(%SearchResult{} = search_result, opts \\ []) do
    attrs = %{
      indexer: search_result.indexer,
      title: search_result.title,
      download_url: search_result.download_url,
      media_item_id: Keyword.get(opts, :media_item_id),
      episode_id: Keyword.get(opts, :episode_id),
      library_path_id: Keyword.get(opts, :library_path_id),
      metadata: Queue.build_download_metadata(search_result)
    }

    supervisor = Keyword.get(opts, :supervisor, @supervisor)

    with {:ok, download} <- History.create_download(attrs) do
      start_result =
        Task.Supervisor.start_child(supervisor, fn ->
          run_grab(download, search_result, opts)
        end)

      case start_result do
        {:error, reason} ->
          # Nothing will ever run `run_grab/3` for this record, so the
          # optimistic row would sit in "grabbing" until the DownloadMonitor
          # sweep times it out — blocking re-grabs of its target for the whole
          # timeout window. Drop it now and let the caller report the failure.
          Logger.error("Could not start grab task",
            download_id: download.id,
            title: download.title,
            reason: inspect(reason)
          )

          History.delete_download(download)
          {:error, {:task_start_failed, reason}}

        _started ->
          {:ok, download}
      end
    end
  end

  @doc false
  # The asynchronous part of the pipeline. Public so tests can run it
  # synchronously without the supervisor.
  @spec run_grab(Download.t(), SearchResult.t(), keyword()) :: :ok | :error | :duplicate
  def run_grab(%Download{} = download, %SearchResult{} = search_result, opts) do
    # Mirror initiate_download/2: normalize metadata before the duplicate
    # check so season-pack-aware guards (check_for_active_download/4) see a
    # %SearchResultMetadata{} rather than a raw map from the caller.
    search_result = Queue.normalize_search_result_metadata(search_result)

    opts =
      opts
      |> Keyword.put(:exclude_download_id, download.id)
      |> Keyword.put(:download_type, search_result.download_protocol)

    case Queue.check_for_duplicate_download(search_result, opts) do
      {:error, reason} when reason in [:duplicate_download, :already_have_files] ->
        History.delete_download(download)

        # Carry the reason the way :grab_failed already does. The two cases mean
        # different things to an operator (something is in flight vs. we already
        # have the files), and collapsing them is what made the original
        # season-pack incident so hard to read.
        broadcast({:grab_duplicate, %{download_url: download.download_url, reason: reason}})

        :duplicate

      :ok ->
        attach_to_client(download, search_result, opts)
    end
  end

  defp attach_to_client(download, search_result, opts) do
    case Queue.select_and_add_to_client(search_result, opts) do
      {:ok, client_config, client_id, _detected_type} ->
        finalize_success(download, client_config.name, client_id, opts)

      {:error, reason} ->
        fail_grab(download, reason)
    end
  end

  defp finalize_success(download, client_name, client_id, opts) do
    case store_client_assignment(download, client_name, client_id) do
      {:ok, download} ->
        emit_initiated_event(download, opts)

        broadcast(
          {:grab_completed, %{download_id: download.id, download_url: download.download_url}}
        )

        :ok

      {:error, changeset} ->
        # The torrent IS in the client, but we couldn't persist the link.
        fail_grab(download, {:record_update_failed, changeset.errors})
    end
  end

  # Persist the client assignment, clearing a stale record that already holds
  # this (client, client_id) pair — mirrors create_download_record_with_retry.
  defp store_client_assignment(download, client_name, client_id) do
    attrs = %{download_client: client_name, download_client_id: client_id}

    case History.update_download(download, attrs) do
      {:ok, updated} ->
        {:ok, updated}

      {:error, changeset} ->
        case find_conflicting_download(client_name, client_id, download.id) do
          nil ->
            {:error, changeset}

          stale ->
            Logger.info("Deleting stale download record before grab finalize",
              download_id: stale.id,
              title: stale.title
            )

            History.delete_download(stale)
            History.update_download(download, attrs)
        end
    end
  end

  defp find_conflicting_download(client_name, client_id, exclude_id) do
    Download
    |> where([d], d.download_client == ^client_name and d.download_client_id == ^client_id)
    |> where([d], d.id != ^exclude_id)
    |> Repo.one()
  end

  defp fail_grab(download, reason) do
    message = format_error(reason)
    Logger.warning("Grab failed for #{download.title}: #{inspect(reason)}")
    History.update_download(download, %{error_message: message})

    broadcast(
      {:grab_failed,
       %{download_id: download.id, download_url: download.download_url, reason: message}}
    )

    :error
  end

  defp emit_initiated_event(download, opts) do
    actor_type = Keyword.get(opts, :actor_type, :user)
    actor_id = Keyword.get(opts, :actor_id, "manual_search")

    download = Repo.preload(download, :media_item)
    Events.download_initiated(download, actor_type, actor_id, media_item: download.media_item)
  end

  defp broadcast(message) do
    PubSub.broadcast(Mydia.PubSub, @topic, message)
  end

  defp format_error({:download_failed, message}) when is_binary(message),
    do: truncate("Failed to fetch release: #{message}")

  defp format_error({:client_error, error}),
    do: truncate("Download client error: #{inspect(error)}")

  defp format_error(:no_clients_configured),
    do: "No download clients are configured"

  defp format_error({:client_not_found, name}),
    do: "Download client not found: #{name}"

  defp format_error(other), do: truncate(inspect(other))

  defp truncate(message), do: String.slice(message, 0, @max_error_length)
end
