defmodule Mydia.Jobs.ImportListSync do
  @moduledoc """
  Oban worker for syncing a single import list.

  This worker fetches items from the import list's source (e.g., TMDB trending),
  compares them with existing items, and adds new items as pending.

  ## Usage

      # Sync a specific list
      Mydia.Jobs.ImportListSync.enqueue(import_list_id)

      # Sync with options
      Mydia.Jobs.ImportListSync.enqueue(import_list_id, auto_add: true)
  """

  use Oban.Worker,
    queue: :import_lists,
    max_attempts: 3,
    unique: [period: 60, keys: [:import_list_id]]

  require Logger

  alias Mydia.ImportLists
  alias Mydia.ImportLists.ImportList
  alias Mydia.ImportLists.Provider.{TMDB, CustomURL}

  defmodule Args do
    @moduledoc false
    defstruct [:import_list_id, auto_add: false]

    @type t :: %__MODULE__{
            import_list_id: String.t() | nil,
            auto_add: boolean() | nil
          }

    def parse(%{"import_list_id" => import_list_id} = raw) do
      %__MODULE__{
        import_list_id: import_list_id,
        auto_add: Map.get(raw, "auto_add", false)
      }
    end
  end

  @spec perform(Oban.Job.t()) :: :ok | {:ok, term()} | {:error, term()} | {:snooze, pos_integer()}
  @impl Oban.Worker
  def perform(%Oban.Job{args: raw_args}) do
    args = Args.parse(raw_args)
    import_list_id = args.import_list_id
    auto_add = args.auto_add

    Logger.info("[ImportListSync] Starting sync",
      import_list_id: import_list_id,
      auto_add: auto_add
    )

    with {:ok, import_list} <- get_import_list(import_list_id),
         :ok <- check_enabled(import_list),
         {:ok, items} <- fetch_items(import_list),
         {:ok, stats} <- process_items(import_list, items) do
      # Mark sync success
      {:ok, _} = ImportLists.mark_sync_success(import_list)

      Logger.info("[ImportListSync] Sync completed",
        import_list_id: import_list_id,
        new_items: stats.new,
        updated_items: stats.updated,
        total_items: stats.total
      )

      # Broadcast sync completion
      Phoenix.PubSub.broadcast(
        Mydia.PubSub,
        "import_lists",
        {:import_list_sync_complete, import_list_id, {:ok, stats}}
      )

      # If auto_add is enabled, trigger auto-add worker
      if auto_add == true || import_list.auto_add do
        enqueue_auto_add(import_list_id)
      end

      :ok
    else
      {:error, :not_found} ->
        Logger.warning("[ImportListSync] Import list not found", import_list_id: import_list_id)
        :ok

      {:error, :disabled} ->
        Logger.debug("[ImportListSync] Import list is disabled", import_list_id: import_list_id)
        :ok

      {:error, reason} = error ->
        # Try to record the error on the list if we have it
        with {:ok, import_list} <- get_import_list(import_list_id) do
          ImportLists.mark_sync_error(import_list, reason)
        end

        Logger.error("[ImportListSync] Sync failed",
          import_list_id: import_list_id,
          error: inspect(reason)
        )

        # Broadcast sync failure
        Phoenix.PubSub.broadcast(
          Mydia.PubSub,
          "import_lists",
          {:import_list_sync_complete, import_list_id, {:error, reason}}
        )

        error
    end
  end

  @doc """
  Enqueues a sync job for a specific import list.

  ## Options
    - `:auto_add` - Override the list's auto_add setting
    - `:schedule_in` - Schedule the job to run after N seconds
  """
  def enqueue(import_list_id, opts \\ []) do
    {schedule_in, job_opts} = Keyword.pop(opts, :schedule_in)

    args = %{
      "import_list_id" => import_list_id,
      "auto_add" => Keyword.get(job_opts, :auto_add)
    }

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

  defp check_enabled(%ImportList{enabled: true}), do: :ok
  defp check_enabled(%ImportList{enabled: false}), do: {:error, :disabled}

  defp fetch_items(%ImportList{} = import_list) do
    # Use appropriate provider based on list type
    cond do
      TMDB.supports?(import_list.type) ->
        TMDB.fetch_items(import_list)

      CustomURL.supports?(import_list.type) ->
        CustomURL.fetch_items(import_list)

      true ->
        {:error, "Unsupported import list type: #{import_list.type}"}
    end
  end

  defp process_items(%ImportList{} = import_list, items) do
    now = DateTime.utc_now()

    stats =
      Enum.reduce(items, %{new: 0, updated: 0, total: 0}, fn item, acc ->
        attrs = %{
          import_list_id: import_list.id,
          tmdb_id: item.tmdb_id,
          title: item.title,
          year: item.year,
          poster_path: item.poster_path,
          discovered_at: now
        }

        case ImportLists.upsert_import_list_item(attrs) do
          {:ok, _item, :created} ->
            %{acc | total: acc.total + 1, new: acc.new + 1}

          {:ok, _item, :updated} ->
            %{acc | total: acc.total + 1, updated: acc.updated + 1}

          {:error, _} ->
            acc
        end
      end)

    {:ok, stats}
  end

  defp enqueue_auto_add(import_list_id) do
    Mydia.Jobs.ImportListAutoAdd.enqueue(import_list_id)
  end
end
