defmodule Mydia.Jobs.ImportListAutoAdd do
  @moduledoc """
  Oban worker for automatically adding pending import list items to the library.

  This worker processes pending items from an import list, fetches full metadata,
  and creates media items in the library. It runs after a sync if auto_add is enabled.

  ## Usage

      # Add pending items from a list
      Mydia.Jobs.ImportListAutoAdd.enqueue(import_list_id)
  """

  use Oban.Worker,
    queue: :import_lists,
    max_attempts: 3,
    unique: [period: 120, keys: [:import_list_id]]

  require Logger

  alias Mydia.ImportLists

  defmodule Args do
    @moduledoc false
    defstruct [:import_list_id]

    @type t :: %__MODULE__{import_list_id: String.t() | nil}

    def parse(%{"import_list_id" => import_list_id}) do
      %__MODULE__{import_list_id: import_list_id}
    end
  end

  # get_import_list/1 can only fail with {:error, :not_found} (its lone rescue
  # clause), and get_pending_items/1's result is bound with a bare variable, so
  # it can never fail the `with`. The only value that can ever reach `else` is
  # {:error, :not_found}; a general {:error, reason} clause here is therefore
  # unreachable, which is why `perform/1`'s own return type is narrowed to
  # :ok below.
  @spec perform(Oban.Job.t()) :: :ok
  @impl Oban.Worker
  def perform(%Oban.Job{args: raw_args}) do
    args = Args.parse(raw_args)
    import_list_id = args.import_list_id
    Logger.info("[ImportListAutoAdd] Starting auto-add", import_list_id: import_list_id)

    with {:ok, import_list} <- get_import_list(import_list_id),
         pending_items <- ImportLists.get_pending_items(import_list) do
      stats = process_pending_items(import_list, pending_items)

      Logger.info("[ImportListAutoAdd] Auto-add completed",
        import_list_id: import_list_id,
        added: stats.added,
        failed: stats.failed
      )

      :ok
    else
      {:error, :not_found} ->
        Logger.warning("[ImportListAutoAdd] Import list not found",
          import_list_id: import_list_id
        )

        :ok
    end
  end

  @doc """
  Enqueues an auto-add job for a specific import list.
  """
  def enqueue(import_list_id, opts \\ []) do
    {schedule_in, _job_opts} = Keyword.pop(opts, :schedule_in)

    args = %{"import_list_id" => import_list_id}

    job =
      if schedule_in do
        new(args, schedule_in: schedule_in)
      else
        new(args)
      end

    Oban.insert(job)
  end

  ## Private Functions

  defp get_import_list(id) do
    try do
      {:ok, ImportLists.get_import_list!(id)}
    rescue
      Ecto.NoResultsError -> {:error, :not_found}
    end
  end

  # Note: a pending item that turns out to already be in the library links to
  # the existing media item and counts as :added, same as a freshly created
  # one (ImportLists.add_item_to_library/2 handles both).
  defp process_pending_items(import_list, pending_items) do
    Enum.reduce(pending_items, %{added: 0, failed: 0}, fn item, acc ->
      case process_item(import_list, item) do
        :added -> %{acc | added: acc.added + 1}
        :failed -> %{acc | failed: acc.failed + 1}
      end
    end)
  end

  defp process_item(import_list, item) do
    case ImportLists.add_item_to_library(item, import_list) do
      {:ok, media_item} ->
        Logger.info("[ImportListAutoAdd] Added media item",
          tmdb_id: item.tmdb_id,
          media_item_id: media_item.id
        )

        :added

      {:error, reason} ->
        Logger.warning("[ImportListAutoAdd] Failed to add item",
          tmdb_id: item.tmdb_id,
          error: inspect(reason)
        )

        :failed
    end
  end
end
