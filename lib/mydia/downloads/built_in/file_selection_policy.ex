defmodule Mydia.Downloads.BuiltIn.FileSelectionPolicy do
  @moduledoc """
  Deselects junk files once per built-in torrent, as soon as its file list is
  known (a magnet has none until its metadata resolves).

  The outcome is recorded in `metadata["file_selection"]`:

    * `%{"source" => "auto", "skipped" => n}` once decided (also for 0)
    * `%{"source" => "auto_pending", "attempts" => n}` after a failed attempt
    * `%{"source" => "auto_failed", "attempts" => 3}` after the third failure

  `auto`, `manual` and `auto_failed` entries are final; the policy never
  overrides an operator's choice. The stored entry is read again before the
  policy acts, so a selection saved after the poll's snapshot still wins.
  """

  alias Mydia.Downloads.{Client, Download, FileSelection, MetadataKey, Queue}
  alias Mydia.Downloads.Structs.EnrichedDownload
  alias Mydia.Repo

  @key "file_selection"
  @final_sources ~w(auto manual auto_failed)
  @max_attempts 3

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
      decide(row, adapter, config, files)
    else
      {:error, reason} -> fail(row, entry, reason)
    end
  end

  defp decide(_row, _adapter, _config, []), do: :waiting

  defp decide(row, adapter, config, files) do
    if final_now?(row.id), do: :done, else: select_files(row, adapter, config, files)
  end

  defp select_files(row, adapter, config, files) do
    keep = FileSelection.keep(files)
    skipped = length(files) - length(keep)

    if skipped == 0 do
      stamp(row, %{"source" => "auto", "skipped" => 0}, :nothing_to_skip)
    else
      case Client.set_file_selection(adapter, config, row.download_client_id, keep) do
        :ok -> stamp(row, %{"source" => "auto", "skipped" => skipped}, :applied)
        {:error, reason} -> fail(row, Map.get(row.metadata || %{}, @key) || %{}, reason)
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

    unless final_now?(row.id), do: MetadataKey.put(row.id, @key, value)
    {:error, reason}
  end

  # The row is the poll's snapshot: the operator may have saved a selection
  # since, and that choice must win. A deleted row needs nothing either.
  defp final_now?(id) do
    case Repo.get(Download, id) do
      %Download{metadata: metadata} -> final?(Map.get(metadata || %{}, @key))
      nil -> true
    end
  end

  defp final?(%{"source" => source}), do: source in @final_sources
  defp final?(_entry), do: false
end
