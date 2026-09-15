defmodule Mydia.Jobs.ShowFileRepair do
  @moduledoc """
  One-shot worker that clears TV files attached straight to their show.

  A TV `media_files` row belongs to an episode. Before
  `Mydia.Library.MediaFile.changeset/2` refused it, download import, the
  show-page re-scan and re-match could write a row with `media_item_id` set to
  a `tv_show` and `episode_id` NULL. The show page lists those as loose files
  and no episode can reach them.

  For each affected show this re-links whatever the filename names via
  `Mydia.Library.match_files_to_episodes/1`, then demotes the rest to import
  candidates under the show's provider identity
  (`Mydia.ImportCandidates.stage_show_file/3`), deleting the row but not the
  bytes. Trashed rows are left for `TrashCleanup`, and extras (`extra_kind`
  set) may legitimately sit on the show. A row with no library path or
  relative path cannot key a candidate, so it is left in place and counted as
  skipped.

  Idempotent by row state with no stamp column, like
  `Mydia.Jobs.MonitoringRepair`: once drained, a boot costs one query that
  returns nothing. It is a boot job rather than a migration because it loads
  `%MediaFile{}` structs, which select every schema column. A migration doing
  that fails on an install that upgrades across a later release adding a
  `media_files` column, since this would run before that column exists.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [
      period: 300,
      fields: [:worker],
      states: [:suspended, :available, :scheduled, :executing, :retryable]
    ]

  import Ecto.Query

  require Logger

  alias Mydia.ImportCandidates
  alias Mydia.Library
  alias Mydia.Library.MediaFile
  alias Mydia.Media.MediaItem
  alias Mydia.Repo

  @default_batch_size 100

  @doc """
  Enqueues the repair. Called at every boot.

  Never raises, for the reason `Mydia.Jobs.HdrBackfill.enqueue_once/0`
  documents: `Mydia.Application.start/2` has no top-level rescue, and a repair
  that can run on the next boot must not take down this one.
  """
  @spec enqueue_once() :: :ok
  def enqueue_once do
    %{} |> new() |> Oban.insert()
    :ok
  rescue
    error ->
      Logger.warning("Show file repair: failed to enqueue on boot", error: inspect(error))
      :ok
  end

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok
  def perform(%Oban.Job{}) do
    {:ok, _result} = run()
    :ok
  end

  @doc """
  Repairs every affected show.

  ## Options

    * `:batch_size` - shows per page (default #{@default_batch_size}). Exists so
      tests can force the pagination boundary.
  """
  @spec run(keyword()) ::
          {:ok,
           %{relinked: non_neg_integer(), demoted: non_neg_integer(), skipped: non_neg_integer()}}
  def run(opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    result = repair_pages(nil, %{relinked: 0, demoted: 0, skipped: 0}, batch_size)

    if result.relinked + result.demoted + result.skipped > 0 do
      Logger.info(
        "Show file repair: relinked #{result.relinked}, demoted #{result.demoted}, " <>
          "skipped #{result.skipped}"
      )
    end

    {:ok, result}
  end

  defp repair_pages(after_id, acc, batch_size) do
    case show_ids(after_id, batch_size) do
      [] ->
        acc

      ids ->
        acc = Enum.reduce(ids, acc, &repair_show/2)
        repair_pages(List.last(ids), acc, batch_size)
    end
  end

  defp show_ids(after_id, batch_size) do
    query =
      from(f in show_level_files(),
        join: m in MediaItem,
        as: :show,
        on: m.id == f.media_item_id,
        where: m.type == "tv_show",
        distinct: true,
        order_by: [asc: m.id],
        limit: ^batch_size,
        select: m.id
      )

    query =
      case after_id do
        nil -> query
        id -> where(query, [show: m], m.id > ^id)
      end

    Repo.all(query)
  end

  # Untrashed, non-extra files attached to an item with no episode. Joined to
  # tv_show items by the callers.
  defp show_level_files do
    from(f in MediaFile,
      where:
        is_nil(f.episode_id) and not is_nil(f.media_item_id) and is_nil(f.trashed_at) and
          is_nil(f.extra_kind)
    )
  end

  defp repair_show(show_id, acc) do
    {:ok, relinked} = Library.match_files_to_episodes(show_id)
    show = Repo.get!(MediaItem, show_id)

    from(f in show_level_files(), where: f.media_item_id == ^show_id, preload: :library_path)
    |> Repo.all()
    |> Enum.reduce(%{acc | relinked: acc.relinked + relinked}, fn file, acc ->
      case demote(show, file) do
        :demoted -> %{acc | demoted: acc.demoted + 1}
        :skipped -> %{acc | skipped: acc.skipped + 1}
      end
    end)
  end

  defp demote(_show, %MediaFile{library_path: nil} = file), do: skip(file, :no_library_path)
  defp demote(_show, %MediaFile{relative_path: nil} = file), do: skip(file, :no_relative_path)

  defp demote(show, file) do
    Repo.transaction(fn ->
      with {:ok, _candidate} <-
             ImportCandidates.stage_show_file(show, file.library_path, %{
               relative_path: file.relative_path,
               size: file.size,
               discovered_at: file.inserted_at
             }),
           {:ok, _deleted} <- Library.delete_media_file(file, delete_files: false) do
        :demoted
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, :demoted} -> :demoted
      {:error, reason} -> skip(file, reason)
    end
  end

  defp skip(file, reason) do
    Logger.warning("Show file repair: left a show-level file in place",
      media_file_id: file.id,
      reason: inspect(reason)
    )

    :skipped
  end
end
