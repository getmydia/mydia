defmodule Mydia.Jobs.TrashAction do
  @moduledoc """
  Restores or purges a batch of trashed media files.

  ## Why this is a job

  Restoring a file moves bytes back onto the library path. A mount that
  dropped and came back trashes an entire library in one scan, so the
  recovery is routinely hundreds of files and tens of terabytes of
  `rename(2)`. That cannot live in a LiveView process the operator can close.

  ## Why the selection can be a filter

  The page is paginated, so the LiveView never holds more than one page of
  ids. "Select all 412 matching Missing" therefore cannot be expressed as an
  id list without silently truncating to the visible page. The job takes the
  filter instead and re-runs the query itself.

  A partial failure is reported, not raised. One file whose bytes will not
  move must not strand the other 411.
  """
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 1

  require Logger

  alias Mydia.Library

  @pubsub Mydia.PubSub
  @topic "trash_actions"

  @doc "PubSub topic the trash page subscribes to."
  def topic, do: @topic

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"action" => action, "selection" => selection}}) do
    files = resolve(selection)
    total = length(files)

    result =
      files
      |> Enum.with_index(1)
      |> Enum.reduce(%{ok: 0, retained: 0, failed: 0}, fn {file, index}, acc ->
        acc = apply_one(action, file, acc)
        broadcast({:trash_action_progress, %{done: index, total: total}})
        acc
      end)

    Logger.info("Bulk trash action complete",
      action: action,
      total: total,
      ok: result.ok,
      retained: result.retained,
      failed: result.failed
    )

    broadcast({:trash_action_done, Map.put(result, :action, action)})
    :ok
  end

  defp apply_one("restore", file, acc) do
    case Library.restore_media_file(file) do
      {:ok, _} -> %{acc | ok: acc.ok + 1}
      {:ok, _, :trash_copy_retained} -> %{acc | retained: acc.retained + 1}
      {:error, _} -> %{acc | failed: acc.failed + 1}
    end
  end

  defp apply_one("purge", file, acc) do
    case Library.purge_media_file(file) do
      :ok -> %{acc | ok: acc.ok + 1}
      {:error, _} -> %{acc | failed: acc.failed + 1}
    end
  end

  defp resolve(%{"type" => "ids", "ids" => ids}) do
    Enum.flat_map(ids, fn id ->
      case Library.get_trashed_media_file(id, preload: [:library_path]) do
        nil -> []
        file -> [file]
      end
    end)
  end

  defp resolve(%{"type" => "all_matching", "reason" => reason}) do
    Library.list_trashed_media_files(
      reason: parse_reason(reason),
      preload: [:library_path]
    )
  end

  # Fixed set, never String.to_atom/1 on job args.
  defp parse_reason(nil), do: nil
  defp parse_reason(""), do: nil
  defp parse_reason("missing"), do: :missing
  defp parse_reason("upgraded"), do: :upgraded
  defp parse_reason("upgrade_rejected"), do: :upgrade_rejected
  defp parse_reason("pruned"), do: :pruned
  defp parse_reason("manual"), do: :manual
  defp parse_reason("unknown"), do: :unknown
  defp parse_reason(_), do: nil

  defp broadcast(message), do: Phoenix.PubSub.broadcast(@pubsub, @topic, message)
end
