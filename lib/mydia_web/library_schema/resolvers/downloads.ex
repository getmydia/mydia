defmodule MydiaWeb.LibrarySchema.Resolvers.Downloads do
  @moduledoc """
  Resolves `downloads`, `cancelDownload` and `rejectRelease`.

  Not paged on purpose: `list_downloads_with_status/1` loads every row and asks
  each enabled client for live status, so the work is per-call rather than
  per-page, and a page size would not bound it.

  The client and indexer are read straight off the enriched struct with no extra
  lookup.
  """

  require Logger

  alias Mydia.Downloads
  alias Mydia.LibraryApi.Principal
  alias Mydia.LibraryApi.RevisionFeed
  alias Mydia.Media
  alias MydiaWeb.LibrarySchema.Loaders
  alias MydiaWeb.LibrarySchema.MediaItemView
  alias MydiaWeb.LibrarySchema.UserError

  @status_map %{
    "queued" => :queued,
    "grabbing" => :grabbing,
    "downloading" => :downloading,
    "checking" => :checking,
    "paused" => :paused,
    "seeding" => :seeding,
    "completed" => :completed,
    "imported" => :imported,
    "failed" => :failed,
    "missing" => :missing,
    "unknown" => :unknown
  }
  @client_state_map %{present: :present, disabled: :disabled, removed: :removed}

  @doc "Maps a derived status string onto the enum, defaulting to :unknown."
  @spec status(String.t() | nil) :: atom()
  def status(value) when is_binary(value), do: Map.get(@status_map, value, :unknown)
  def status(_value), do: :unknown

  @doc "Maps a client config state onto the enum, defaulting to :unknown."
  @spec client_state(atom() | nil) :: atom()
  def client_state(value), do: Map.get(@client_state_map, value, :unknown)

  @spec downloads(any(), map(), Absinthe.Resolution.t()) :: {:ok, [map()]}
  def downloads(_parent, args, _info) do
    filter = Map.get(args, :filter) || :active
    rows = Downloads.list_downloads_with_status(filter: filter)
    {items, changed_at_by_id, episodes} = hydrate_associations(rows)

    {:ok, Enum.map(rows, &download_map(&1, items, changed_at_by_id, episodes))}
  end

  @spec cancel_download(any(), map(), Absinthe.Resolution.t()) :: {:ok, map()}
  def cancel_download(_parent, %{id: id}, resolution) do
    opts = Principal.actor_opts(resolution.context.principal)

    with {:ok, download} <- Loaders.download(id, ["id"]),
         {:ok, _cancelled} <- Downloads.cancel_download(download, opts) do
      {:ok, removed(download.id)}
    else
      {:error, %UserError{} = error} ->
        {:ok, not_removed(error)}

      # cancel_download/2 stops at the client and keeps the row when the client
      # cannot remove the item, so the download is still there to retry. The
      # reason can carry a raw adapter response, so it is logged, not returned.
      {:error, reason} ->
        Logger.warning(
          "Library API cancelDownload failed to remove from client: #{inspect(reason)}"
        )

        message = "The download client could not remove it"
        {:ok, not_removed(UserError.new(:client_unavailable, message, ["id"]))}
    end
  end

  @spec reject_release(any(), map(), Absinthe.Resolution.t()) ::
          {:ok, map()} | {:error, String.t()}
  def reject_release(_parent, %{id: id} = args, resolution) do
    with {:ok, days} <- blocklist_days(Map.get(args, :blocklist_days)),
         {:ok, download} <- Loaders.download(id, ["id"]),
         opts = reject_opts(resolution.context.principal, days),
         {:ok, :rejected} <- Downloads.reject_release(download, opts) do
      {:ok, removed(download.id)}
    else
      {:error, %UserError{} = error} ->
        {:ok, not_removed(error)}

      {:error, reason} ->
        Logger.warning("Library API rejectRelease failed: #{inspect(reason)}")
        {:error, "Could not reject the release"}
    end
  end

  defp blocklist_days(nil), do: {:ok, nil}
  defp blocklist_days(days) when is_integer(days) and days >= 1, do: {:ok, days}

  defp blocklist_days(_days),
    do: {:error, UserError.new(:invalid_input, "Must be at least 1", ["blocklistDays"])}

  # Only an explicit value is forwarded, so an omitted one keeps reject_release/2's
  # configured default.
  defp reject_opts(principal, nil), do: Principal.actor_opts(principal)

  defp reject_opts(principal, days),
    do: Keyword.put(Principal.actor_opts(principal), :ttl_days, days)

  defp removed(id), do: %{removed_id: id, user_errors: []}
  defp not_removed(error), do: %{removed_id: nil, user_errors: [error]}

  # History only preloads episode.media_item. Batch the standard API preloads
  # so nested availability and episode.hasFile never read unloaded associations,
  # and batch the items' aggregate revision timestamps in the same pass so a
  # queue listing never runs one marker query per row.
  defp hydrate_associations(rows) do
    item_ids =
      rows
      |> Enum.flat_map(fn row ->
        [row.media_item_id, row.episode && row.episode.media_item_id]
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    items =
      case item_ids do
        [] -> []
        ids -> Media.list_media_items(ids: ids, preload: MediaItemView.preloads())
      end

    by_id = Map.new(items, &{&1.id, &1})
    changed_at_by_id = RevisionFeed.changed_at_by_ids(Enum.map(items, & &1.id))

    episodes =
      items
      |> Enum.flat_map(& &1.episodes)
      |> Map.new(&{&1.id, &1})

    {by_id, changed_at_by_id, episodes}
  end

  defp download_map(row, items, changed_at_by_id, episodes) do
    %{
      id: row.id,
      title: row.title,
      status: status(row.status),
      progress: row.progress,
      size_bytes: row.size,
      downloaded_bytes: row.downloaded,
      eta_seconds: row.eta,
      download_client: client(row),
      indexer: indexer(row),
      error_message: row.error_message,
      import_failure_reason: row.import_failure_reason,
      import_failed_at: row.import_failed_at,
      media_item: media_item(row.media_item_id, items, changed_at_by_id),
      episode: episode(row.episode_id, episodes),
      added_at: row.inserted_at
    }
  end

  defp media_item(nil, _items, _changed_at_by_id), do: nil

  defp media_item(id, items, changed_at_by_id) do
    case Map.get(items, id) do
      nil -> nil
      item -> MediaItemView.item_map(item, Map.fetch!(changed_at_by_id, id))
    end
  end

  defp episode(nil, _episodes), do: nil

  defp episode(id, episodes) do
    case Map.get(episodes, id) do
      nil -> nil
      episode -> MediaItemView.episode_map(episode)
    end
  end

  defp client(%{download_client: nil}), do: nil

  defp client(row) do
    %{name: row.download_client, state: client_state(row.client_config_state)}
  end

  defp indexer(%{indexer: nil}), do: nil
  defp indexer(row), do: %{name: row.indexer}
end
