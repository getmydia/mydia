defmodule MydiaWeb.LibrarySchema.Resolvers.Downloads do
  @moduledoc """
  Resolves `downloads`.

  Not paged on purpose: `list_downloads_with_status/1` loads every row and asks
  each enabled client for live status, so the work is per-call rather than
  per-page, and a page size would not bound it.

  The client and indexer are read straight off the enriched struct with no extra
  lookup.
  """

  alias Mydia.Downloads
  alias Mydia.Media
  alias MydiaWeb.LibrarySchema.MediaItemView

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
    {items, episodes} = hydrate_associations(rows)

    {:ok, Enum.map(rows, &download_map(&1, items, episodes))}
  end

  # History only preloads episode.media_item. Batch the standard API preloads
  # so nested availability and episode.hasFile never read unloaded associations.
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
        [] -> %{}
        ids -> Media.list_media_items(ids: ids, preload: MediaItemView.preloads())
      end
      |> Map.new(&{&1.id, &1})

    episodes =
      items
      |> Map.values()
      |> Enum.flat_map(& &1.episodes)
      |> Map.new(&{&1.id, &1})

    {items, episodes}
  end

  defp download_map(row, items, episodes) do
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
      media_item: media_item(row.media_item_id, items),
      episode: episode(row.episode_id, episodes),
      added_at: row.inserted_at
    }
  end

  defp media_item(nil, _items), do: nil

  defp media_item(id, items) do
    case Map.get(items, id) do
      nil -> nil
      item -> MediaItemView.item_map(item)
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
