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

  alias Mydia.Accounts.Scope
  alias Mydia.ImportLists
  alias Mydia.Media

  defmodule Args do
    @moduledoc false
    defstruct [:import_list_id]

    @type t :: %__MODULE__{import_list_id: String.t() | nil}

    def parse(%{"import_list_id" => import_list_id}) do
      %__MODULE__{import_list_id: import_list_id}
    end
  end

  @spec perform(Oban.Job.t()) :: :ok | {:ok, term()} | {:error, term()} | {:snooze, pos_integer()}
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
        skipped: stats.skipped,
        failed: stats.failed
      )

      :ok
    else
      {:error, :not_found} ->
        Logger.warning("[ImportListAutoAdd] Import list not found",
          import_list_id: import_list_id
        )

        :ok

      {:error, reason} ->
        Logger.error("[ImportListAutoAdd] Auto-add failed",
          import_list_id: import_list_id,
          error: inspect(reason)
        )

        {:error, reason}
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

  defp process_pending_items(import_list, pending_items) do
    Enum.reduce(pending_items, %{added: 0, skipped: 0, failed: 0}, fn item, acc ->
      case process_item(import_list, item) do
        :added -> %{acc | added: acc.added + 1}
        :skipped -> %{acc | skipped: acc.skipped + 1}
        :failed -> %{acc | failed: acc.failed + 1}
      end
    end)
  end

  defp process_item(import_list, item) do
    # First check if already in library
    case ImportLists.check_duplicate(item.tmdb_id, import_list.media_type) do
      {:duplicate, media_item} ->
        # Already exists, mark as skipped
        ImportLists.mark_item_skipped(item, "Already in library")
        # Link to existing media item
        ImportLists.mark_item_added(item, media_item.id)
        :skipped

      :not_found ->
        # Try to add to library
        add_to_library(import_list, item)
    end
  end

  defp add_to_library(import_list, item) do
    # Fetch full metadata
    config = Mydia.Metadata.default_relay_config()
    tmdb_id = to_string(item.tmdb_id)

    media_type =
      case import_list.media_type do
        "movie" -> :movie
        "tv_show" -> :tv_show
        mt -> mt
      end

    # Import lists typically have TMDB IDs, so use provider: :tmdb to force TMDB fetch
    fetch_opts = [media_type: media_type, provider: :tmdb]

    case Mydia.Metadata.fetch_by_id(config, tmdb_id, fetch_opts) do
      {:ok, metadata} ->
        create_media_item(import_list, item, metadata, config)

      {:error, reason} ->
        Logger.warning("[ImportListAutoAdd] Failed to fetch metadata",
          tmdb_id: item.tmdb_id,
          error: inspect(reason)
        )

        ImportLists.mark_item_failed(item, "Failed to fetch metadata")
        :failed
    end
  end

  defp create_media_item(import_list, item, metadata, config) do
    attrs = %{
      type: import_list.media_type,
      title: metadata.title,
      original_title: metadata.original_title,
      year: metadata.year,
      tmdb_id: item.tmdb_id,
      imdb_id: metadata.imdb_id,
      metadata: metadata,
      monitored: import_list.monitored,
      quality_profile_id: import_list.quality_profile_id
    }

    # For TV shows, look up TVDB ID via search
    attrs =
      if import_list.media_type == "tv_show" do
        lookup_tvdb_id(attrs, config)
      else
        attrs
      end

    case Media.create_media_item(Scope.system(), attrs) do
      {:ok, media_item} ->
        ImportLists.mark_item_added(item, media_item.id)
        maybe_add_to_target_collection(import_list, media_item)

        Logger.info("[ImportListAutoAdd] Added media item",
          title: metadata.title,
          tmdb_id: item.tmdb_id,
          media_item_id: media_item.id
        )

        :added

      {:error, changeset} ->
        error_message = format_changeset_errors(changeset)

        Logger.warning("[ImportListAutoAdd] Failed to create media item",
          tmdb_id: item.tmdb_id,
          error: error_message
        )

        ImportLists.mark_item_failed(item, error_message)
        :failed
    end
  end

  defp maybe_add_to_target_collection(%{target_collection_id: nil}, _media_item), do: :ok

  defp maybe_add_to_target_collection(%{target_collection_id: collection_id}, media_item) do
    alias Mydia.Collections

    case Collections.get_collection_by_id(collection_id) do
      nil ->
        Logger.debug("[ImportListAutoAdd] Target collection not found, skipping",
          collection_id: collection_id
        )

        :ok

      collection ->
        if collection.type == "manual" do
          case Collections.add_item(collection, media_item.id) do
            {:ok, _} ->
              Logger.info("[ImportListAutoAdd] Added to target collection",
                collection_id: collection_id,
                media_item_id: media_item.id
              )

            {:error, reason} ->
              Logger.warning("[ImportListAutoAdd] Failed to add to target collection",
                collection_id: collection_id,
                error: inspect(reason)
              )
          end
        end

        :ok
    end
  end

  # Look up the TVDB ID for a TV show by searching TVDB by title+year
  defp lookup_tvdb_id(attrs, config) do
    search_opts =
      if attrs[:year] do
        [media_type: :tv_show, provider: :tvdb, year: attrs[:year]]
      else
        [media_type: :tv_show, provider: :tvdb]
      end

    case Mydia.Metadata.search(config, attrs.title, search_opts) do
      {:ok, [first | _]} ->
        case Integer.parse(first.provider_id) do
          {tvdb_id, ""} -> Map.put(attrs, :tvdb_id, tvdb_id)
          _ -> attrs
        end

      _ ->
        attrs
    end
  end

  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join("; ", fn {field, errors} -> "#{field}: #{Enum.join(errors, ", ")}" end)
  end
end
