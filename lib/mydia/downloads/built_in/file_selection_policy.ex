defmodule Mydia.Downloads.BuiltIn.FileSelectionPolicy do
  @moduledoc """
  Deselects junk files once per built-in torrent, as soon as its file list is
  known (a magnet has none until its metadata resolves).

  The outcome is recorded in `metadata["file_selection"]`:

    * `%{"source" => "auto", "skipped" => n}` once decided (also for 0)
    * `%{"source" => "auto_pending", "attempts" => n}` after a failed attempt
    * `%{"source" => "auto_failed", "attempts" => 3}` after the third failure

  `auto`, `manual` and `auto_failed` entries are final; the policy never
  overrides an operator's choice. A torrent whose files
  `Mydia.Downloads.WantedFiles` chose before the add already carries an
  `auto` entry (`auto_entry/1`), so the policy never re-selects what that
  selection skipped. The stored entry is read again before the
  policy acts, under `Mydia.Downloads.TorrentFiles.with_selection_lock/2`
  (which the operator's save also holds), so a selection saved after the
  poll's snapshot still wins and a save never lands between the check and the
  policy's client write.
  """

  alias Mydia.Downloads.{Client, Download, FileSelection, MetadataKey, Queue, TorrentFiles}
  alias Mydia.Downloads.Structs.EnrichedDownload
  alias Mydia.Repo

  @key "file_selection"
  @final_sources ~w(auto manual auto_failed)
  @max_attempts 3

  @doc "The metadata key this policy reads and writes."
  @spec metadata_key() :: String.t()
  def metadata_key, do: @key

  @doc """
  The final entry for a torrent whose files were chosen automatically, with
  `skipped` files left out. `Mydia.Downloads.WantedFiles` records it at grab
  when it already chose the files, so this policy leaves the torrent alone.
  """
  @spec auto_entry(non_neg_integer()) :: map()
  def auto_entry(skipped) when is_integer(skipped) and skipped >= 0,
    do: %{"source" => "auto", "skipped" => skipped}

  @spec apply(EnrichedDownload.t()) ::
          :applied | :nothing_to_skip | :waiting | :done | {:error, term()}
  def apply(%EnrichedDownload{} = row) do
    entry = Map.get(row.metadata || %{}, @key) || %{}

    cond do
      not is_nil(row.imported_at) -> :done
      final?(entry) -> :done
      row.status == "checking" -> :waiting
      true -> select(row, entry)
    end
  end

  defp select(row, entry) do
    with {:ok, adapter, config} <- Queue.resolve_adapter(row.download_client),
         {:ok, files} <- Client.torrent_files(adapter, config, row.download_client_id) do
      decide(row, entry, adapter, config, files)
    else
      {:error, reason} -> fail(row, entry, reason)
    end
  end

  defp decide(_row, _entry, _adapter, _config, []), do: :waiting

  # The final check, the client write and the stamp hold the lock the
  # operator's save takes, so a save cannot land between them. A failed
  # client write is recorded after the lock is released (`fail/3` takes it).
  defp decide(row, entry, adapter, config, files) do
    locked =
      TorrentFiles.with_selection_lock(row.id, fn ->
        if final_now?(row.id), do: :done, else: select_files(row, adapter, config, files)
      end)

    case locked do
      {:client_error, reason} -> fail(row, entry, reason)
      outcome -> outcome
    end
  end

  defp select_files(row, adapter, config, files) do
    keep = FileSelection.keep(files)
    skipped = length(files) - length(keep)

    if skipped == 0 do
      stamp(row, auto_entry(0), :nothing_to_skip)
    else
      case Client.set_file_selection(adapter, config, row.download_client_id, keep) do
        :ok -> stamp(row, auto_entry(skipped), :applied)
        {:error, reason} -> {:client_error, reason}
      end
    end
  end

  defp stamp(row, value, outcome) do
    with :ok <- MetadataKey.put(row.id, @key, value), do: outcome
  end

  defp fail(row, entry, reason) do
    attempts = (entry["attempts"] || 0) + 1

    value =
      if attempts >= @max_attempts,
        do: %{"source" => "auto_failed", "attempts" => @max_attempts},
        else: %{"source" => "auto_pending", "attempts" => attempts}

    TorrentFiles.with_selection_lock(row.id, fn ->
      unless final_now?(row.id), do: MetadataKey.put(row.id, @key, value)
    end)

    {:error, reason}
  end

  # The row is the poll's snapshot: the operator may have saved a selection
  # since, and that choice must win; the import may have finished since, and
  # an imported torrent is never touched. A deleted row needs nothing either.
  defp final_now?(id) do
    case Repo.get(Download, id) do
      %Download{imported_at: nil, metadata: metadata} -> final?(Map.get(metadata || %{}, @key))
      _imported_or_deleted -> true
    end
  end

  defp final?(%{"source" => source}), do: source in @final_sources
  defp final?(_entry), do: false
end
