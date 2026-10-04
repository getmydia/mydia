defmodule Mydia.Jobs.MetadataBackfill do
  @moduledoc """
  Repairs media items that need a metadata refresh to become correct.

  Three cases qualify. Items stored with no `metadata` at all render as an empty
  poster placeholder forever; approving a media request used to create them,
  which is fixed at the source in `Mydia.MediaRequests.approve_request/3`. TV
  shows missing either provider id make Discover show an Add button for
  something already in the library; with one id present the add that follows
  dies on the `tvdb_id` unique index, and with neither it silently creates a
  second row for the same show.

  The third is metadata stored before its parser learned a field. Nothing else
  reaches those items reliably: refresh-all covers monitored items only. When
  parsing starts producing a field that older blobs lack, bump
  `MediaMetadata`'s `@schema_version` and add the affected provider and type to
  `@required_versions` here. These refreshes skip episodes, since a version
  bump describes the show blob only.

  Runs daily. Refreshes are enqueued `@stagger_seconds` apart with
  `scheduled_in`, so a version bump that selects a whole library spreads its
  relay load over hours instead of arriving as a burst. The query matches
  nothing once the library is repaired, so the job settles into costing one
  read. Idempotent and safe to re-run.
  """

  use Oban.Worker,
    queue: :media,
    max_attempts: 3,
    unique: [
      period: 86_400,
      states: [:suspended, :available, :scheduled, :executing, :retryable]
    ]

  require Logger

  import Ecto.Query

  alias Mydia.Jobs.MetadataRefresh
  alias Mydia.Media.MediaItem
  alias Mydia.Media.Refresh
  alias Mydia.Metadata.Structs.MediaMetadata
  alias Mydia.Repo

  @stagger_seconds 15

  # {provider, media_item.type} => minimum MediaMetadata schema_version.
  # 1: TVDB shows stored before cast was parsed from TVDB `characters`.
  @required_versions %{{:tvdb, "tv_show"} => 1}

  @repair_types Enum.uniq(["tv_show" | Enum.map(Map.keys(@required_versions), &elem(&1, 1))])

  # A library large enough to outlast the 24 hours between runs must not have
  # its still-scheduled refreshes queued a second time.
  @refresh_unique [
    period: :infinity,
    keys: [:media_item_id],
    states: [:available, :scheduled, :executing, :retryable]
  ]

  @spec perform(Oban.Job.t()) :: :ok
  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    repairs =
      from(m in MediaItem,
        where: is_nil(m.metadata) or m.type in ^@repair_types,
        select: struct(m, [:id, :type, :metadata, :metadata_source, :tmdb_id, :tvdb_id]),
        order_by: [asc: m.title]
      )
      |> Repo.all()
      |> Enum.flat_map(fn item ->
        case repair(item) do
          :none -> []
          mode -> [{item.id, mode}]
        end
      end)

    if repairs != [] do
      Logger.info("[MetadataBackfill] Found #{length(repairs)} media items needing repair")

      repairs
      |> Enum.with_index()
      |> Enum.each(fn {{id, mode}, index} ->
        enqueue_refresh(id, mode, index * @stagger_seconds)
      end)
    end

    :ok
  end

  defp repair(%MediaItem{metadata: nil}), do: :full

  defp repair(%MediaItem{} = item) do
    cond do
      missing_cross_reference?(item) -> :full
      outdated?(item) -> :metadata_only
      true -> :none
    end
  end

  # The stored metadata is its own marker. Metadata written before
  # cross-provider id storage has `external_ids` nil, which means we have never
  # asked its provider for a cross-reference. Anything written since always
  # carries the map, even when every entry inside is nil, so a show that
  # neither provider cross-references drops out after one refresh instead of
  # being re-enqueued every night.
  defp missing_cross_reference?(
         %MediaItem{type: "tv_show", metadata: %MediaMetadata{external_ids: ids}} = item
       )
       when not is_map(ids),
       do: is_nil(item.tmdb_id) or is_nil(item.tvdb_id)

  defp missing_cross_reference?(%MediaItem{}), do: false

  # Keyed by the provider the refresh would actually call, not the blob's
  # `provider` field, which older blobs may store as `:metadata_relay`.
  defp outdated?(%MediaItem{metadata: %MediaMetadata{} = metadata} = item) do
    {_id, provider} = Refresh.resolve_provider(item)
    required = Map.get(@required_versions, {provider, item.type}, 0)
    (metadata.schema_version || 0) < required
  end

  defp outdated?(%MediaItem{}), do: false

  defp enqueue_refresh(media_item_id, mode, delay_seconds) do
    # Singular Oban.insert/1, never insert_all/1: uniqueness on Basic and Lite
    # is only applied by the singular path.
    media_item_id
    |> refresh_args(mode)
    |> MetadataRefresh.new(scheduled_in: delay_seconds, unique: @refresh_unique)
    |> Oban.insert()
    |> case do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[MetadataBackfill] Could not enqueue refresh for #{media_item_id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp refresh_args(id, :full), do: %{media_item_id: id}
  defp refresh_args(id, :metadata_only), do: %{media_item_id: id, fetch_episodes: false}
end
