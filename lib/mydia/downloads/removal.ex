defmodule Mydia.Downloads.Removal do
  @moduledoc """
  Removes a download the operator asked to remove, from its client and from Mydia.

  A client can take a long time to answer a remove that deletes data.
  Transmission answers no RPC at all while it deletes, which took about 12
  seconds for one Blu-ray season pack. `request/3` writes the intent onto the
  row and enqueues `Mydia.Jobs.RemoveDownload`, so the click returns at once and
  the page shows the row as being removed. `perform/2` is that job's body.

  The row carries the whole intent. The job's only argument is the download id,
  so retrying a removal that gave up needs nothing from the job that gave up.

    * pending: `removal_requested_at` is set
    * failed: `removal_requested_at` is nil and `removal_error` is set
  """

  import Ecto.Query, warn: false

  require Logger

  alias Mydia.DB
  alias Mydia.Downloads.Client
  alias Mydia.Downloads.ClientRemoval
  alias Mydia.Downloads.Download
  alias Mydia.Downloads.History
  alias Mydia.Downloads.Queue
  alias Mydia.Events
  alias Mydia.Jobs.RemoveDownload
  alias Mydia.Repo

  @kinds ~w(cancel clear reject)

  # Status polls keep the adapters' 30-second default. A remove that deletes a
  # large torrent's data can take longer, and timing out early reported a
  # failure while the client went on deleting.
  @remove_timeout_ms :timer.minutes(5)

  @doc """
  Records that `download` should be removed and enqueues the job that does it.

  Returns `{:ok, :already_pending}` without writing when a removal is already in
  flight, and `{:error, :not_found}` when the row is gone.

  ## Options
    - `:delete_files` - passed to the adapter; defaults to `false`
  """
  @spec request(Download.t(), String.t(), keyword()) ::
          {:ok, Download.t()} | {:ok, :already_pending} | {:error, term()}
  def request(%Download{id: id}, kind, opts \\ []) when kind in @kinds do
    request_locked(id, kind, Keyword.get(opts, :delete_files, false), fn _download -> :ok end)
  end

  defp request_locked(id, kind, delete_files, before_mark) do
    Repo.transaction(fn ->
      query = where(Download, [d], d.id == ^id)
      query = if DB.postgres?(), do: lock(query, "FOR UPDATE"), else: query

      case Repo.one(query) do
        nil ->
          Repo.rollback(:not_found)

        %Download{removal_requested_at: %DateTime{}} ->
          :already_pending

        current ->
          :ok = before_mark.(current)
          mark_pending(current, kind, delete_files)
      end
    end)
    |> case do
      {:ok, %Download{} = updated} ->
        # After the commit, so a page that reloads on this message sees the
        # pending row.
        History.broadcast_download_update(updated.id)
        {:ok, updated}

      other ->
        other
    end
  end

  @doc """
  Blacklists the release now, then requests a `"reject"` removal.

  The blacklist entry should filter the release out of the very next search.
  The replacement search itself waits for the job: while the row exists it
  still occupies its target, and the search would skip the grab.
  """
  @spec request_reject(Download.t(), keyword()) ::
          {:ok, Download.t()} | {:ok, :already_pending} | {:error, term()}
  def request_reject(%Download{id: id}, opts \\ []) do
    request_locked(id, "reject", true, &Queue.blacklist_release(&1, opts))
  end

  @doc """
  Requests a `"clear"` removal for every imported download not already pending,
  and returns how many it requested.
  """
  @spec request_clear_all_completed(keyword()) :: {:ok, non_neg_integer()}
  def request_clear_all_completed(opts \\ []) do
    delete_files = Keyword.get(opts, :delete_files, false)

    count =
      Download
      |> where([d], not is_nil(d.imported_at) and is_nil(d.removal_requested_at))
      |> Repo.all()
      |> Enum.count(&match?({:ok, %Download{}}, request(&1, "clear", delete_files: delete_files)))

    {:ok, count}
  end

  @doc """
  The body of `Mydia.Jobs.RemoveDownload`.

  Before the last attempt a failure is returned so Oban retries. On the last
  attempt it is recorded on the row and `:ok` is returned.
  """
  @spec perform(String.t(), boolean()) :: :ok | {:error, term()}
  def perform(download_id, last_attempt?) do
    case Repo.get(Download, download_id) do
      %Download{removal_requested_at: %DateTime{}} = download ->
        with :ok <- remove_from_client(download),
             :ok <- finish(download) do
          :ok
        else
          {:error, reason} when last_attempt? -> give_up(download, reason)
          {:error, _reason} = error -> error
        end

      # Deleted already, or no longer pending because an earlier run gave up.
      _other ->
        :ok
    end
  end

  defp mark_pending(download, kind, delete_files) do
    attrs = %{
      removal_requested_at: DateTime.utc_now() |> DateTime.truncate(:second),
      removal_kind: kind,
      removal_delete_files: delete_files,
      removal_error: nil
    }

    with {:ok, updated} <- download |> Download.changeset(attrs) |> Repo.update(),
         {:ok, _job} <- insert_job(RemoveDownload.new(%{"download_id" => updated.id})) do
      updated
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp remove_from_client(%Download{download_client: nil}), do: :ok
  defp remove_from_client(%Download{download_client_id: nil}), do: :ok

  defp remove_from_client(%Download{} = download) do
    case Queue.client_for(download.download_client) do
      {:ok, adapter, config} ->
        adapter
        |> Client.remove_download(
          with_remove_timeout(config),
          download.download_client_id,
          delete_files: download.removal_delete_files
        )
        |> removed?()

      # A client that is gone or switched off holds nothing Mydia can reach.
      # Clearing the row anyway is what clear_completed/2 and reject_release/2
      # have always done here.
      {:error, :no_client} ->
        Logger.info("Removing a download whose client is not configured or is disabled",
          download_id: download.id,
          client: download.download_client
        )

        :ok
    end
  rescue
    exception -> {:error, exception}
  catch
    # The debrid adapter's remove_torrent/3 can exit instead of raising; see
    # Queue's own remove_from_client/1.
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp removed?(:ok), do: :ok

  defp removed?({:error, error}) do
    if ClientRemoval.not_found_error?(error), do: :ok, else: {:error, error}
  end

  defp with_remove_timeout(config) do
    Map.update(
      config,
      :options,
      %{timeout: @remove_timeout_ms},
      &Map.put(&1, :timeout, @remove_timeout_ms)
    )
  end

  defp finish(%Download{} = download) do
    # Built before the delete, as Queue.finish_reject/2 does: it reads through
    # the media_item association.
    search = if download.removal_kind == "reject", do: Queue.replacement_search(download)

    Repo.transaction(fn -> delete_and_enqueue(download, search) end)
    |> case do
      {:ok, :deleted} ->
        # History.delete_download/1 broadcast from inside the transaction, where
        # a page reloading on that message could still read the row and keep
        # showing it as removing. Say it again now the delete is committed.
        History.broadcast_download_update(download.id)
        announce(download)

      {:ok, :already_deleted} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    exception -> {:error, exception}
  end

  defp delete_and_enqueue(download, search) do
    case History.delete_download(download) do
      {:ok, _deleted} ->
        case Queue.enqueue_search(search) do
          :ok -> :deleted
          {:ok, _job} -> :deleted
          {:error, reason} -> Repo.rollback(reason)
          other -> Repo.rollback({:unexpected_enqueue_result, other})
        end

      {:error, changeset} ->
        if History.stale_changeset?(changeset) do
          :already_deleted
        else
          Repo.rollback(changeset)
        end
    end
  end

  defp announce(%Download{removal_kind: "clear"} = download) do
    Events.download_cleared(download, :user, "unknown")
    :ok
  end

  defp announce(%Download{} = download) do
    Events.download_cancelled(download, :user, "unknown")
    :ok
  end

  defp give_up(%Download{} = download, reason) do
    Logger.warning("Gave up removing a download",
      download_id: download.id,
      client: download.download_client,
      reason: inspect(reason)
    )

    attrs = %{removal_requested_at: nil, removal_error: describe(reason)}

    case History.update_download(download, attrs) do
      {:ok, _updated} -> :ok
      # Deleted in the meantime, which is the outcome the operator wanted.
      {:error, _changeset} -> :ok
    end
  end

  defp describe(%Mydia.Downloads.Client.Error{message: message}), do: message
  defp describe(%{__exception__: true} = exception), do: Exception.message(exception)
  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)

  # Same fallback as Queue's insert_job/1: Oban.insert/1 raises when Oban is not
  # running, which is the case in some test environments.
  defp insert_job(changeset) do
    Oban.insert(changeset)
  rescue
    RuntimeError -> Repo.insert(changeset)
  end
end
