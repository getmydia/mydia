defmodule Mydia.Media.Refresh do
  @moduledoc """
  Owns refreshing a single media item's metadata from its provider.

  This module is the single source of truth for the refresh flow. Before it
  existed the same sequence was written three times (the Oban job, the `Media`
  context, and the show LiveView) and the copies had drifted apart, which is
  how a crash reached production: the job resolved providers using
  `media_item.metadata["id"]`, and `%MediaMetadata{}` does not implement
  `Access`.
  """

  require Logger

  alias Mydia.Accounts.Scope
  alias Mydia.Media
  alias Mydia.Media.ExternalIds
  alias Mydia.Media.MediaItem
  alias Mydia.Metadata
  alias Mydia.Metadata.NfoWriter
  alias Mydia.Metadata.Structs.MediaMetadata

  @typedoc "A resolved provider id and the provider that owns it."
  @type resolution :: {pos_integer() | nil, :tvdb | :tmdb | nil}

  @doc """
  Refreshes one media item's metadata from its provider.

  ## Options

    * `:config` - relay config. Defaults to `Metadata.default_relay_config/0`.
    * `:fetch_episodes` - refresh episodes for TV shows. Defaults to `true`.
    * `:recover_by_title` - when no provider id can be resolved, search the
      provider by title to re-identify the item. Defaults to `false`, because
      fuzzy re-identification is surprising when triggered from a UI button.
    * `:force` - refresh episodes even when `seasons_refreshed_at` is inside
      the throttle window. Defaults to `false`.

      The throttle exists to keep the weekly sweep off the relay, and it is
      right for a sweep. It is wrong for a person: someone who clicked
      "Refresh metadata" is asking for the work to happen now, and the throttle
      silently declines the episode half of it for 24 hours, or 168 once the
      show has ended, while the item row still updates and the flash still
      says it worked. Every UI-initiated refresh passes `force: true`.
  """
  @spec run(MediaItem.t(), keyword()) :: {:ok, MediaItem.t()} | {:error, term()}
  def run(%MediaItem{} = media_item, opts \\ []) do
    config = Keyword.get(opts, :config) || Metadata.default_relay_config()
    fetch_episodes = Keyword.get(opts, :fetch_episodes, true)
    media_type = media_type(media_item)

    recover? = Keyword.get(opts, :recover_by_title, false)

    case resolve_or_recover(media_item, media_type, recover?, config) do
      {nil, _source, _item} ->
        {:error, :missing_provider_id}

      {provider_id, source, item} ->
        with {:ok, metadata} <- fetch(item, provider_id, media_type, source, config),
             {:ok, updated} <- apply_metadata(item, metadata, source) do
          reclassified = reclassify_after_refresh(updated)
          post_update(reclassified, media_type, fetch_episodes, config, opts)
          {:ok, reclassified}
        end
    end
  end

  # Classification was computed once at creation and never again, so a provider
  # that later added or removed a genre left the category stale forever. The
  # hook belongs here rather than in Media.refresh_metadata/2, which is a bare
  # delegate: every other caller of run/2, including the weekly MetadataRefresh
  # sweep, has to get the same treatment.
  #
  # A classification failure must not fail the refresh, matching how
  # Media.auto_classify_media_item/1 already degrades.
  defp reclassify_after_refresh(%MediaItem{} = media_item) do
    case Media.reclassify_media_item(media_item) do
      {:ok, reclassified} -> reclassified
      {:error, _changeset} -> media_item
    end
  end

  # Returns the item alongside the resolution because recovery persists the
  # discovered id; downstream steps must see the updated struct.
  defp resolve_or_recover(media_item, media_type, recover?, config) do
    case resolve_provider(media_item) do
      {nil, _source} when recover? ->
        recover(media_item, media_type, config)

      {nil, _source} ->
        {nil, nil, media_item}

      {provider_id, source} ->
        {provider_id, source, media_item}
    end
  end

  defp recover(media_item, media_type, config) do
    Logger.info("No provider id found, attempting recovery by title search",
      media_item_id: media_item.id,
      title: media_item.title
    )

    case Media.recover_provider_id_by_title(media_item, media_type, config) do
      {:ok, _found_id, updated_item} ->
        # Recovery persists the id to the correct column, so re-resolving the
        # updated item yields the authoritative {id, source} pair.
        {id, source} = resolve_provider(updated_item)
        {id, source, updated_item}

      {:error, reason} ->
        Logger.warning("Failed to recover provider id by title search",
          media_item_id: media_item.id,
          title: media_item.title,
          reason: inspect(reason)
        )

        {nil, nil, media_item}
    end
  end

  defp media_type(%MediaItem{type: "tv_show"}), do: :tv_show
  defp media_type(%MediaItem{}), do: :movie

  # `season_order` rides along so the seasons stored in the metadata blob
  # describe the same ordering the episode rows use. Dropping it here would let
  # the show page render the official season list over DVD-ordered episodes.
  # nil means "never asked" and resolves to TVDB's official ordering.
  defp fetch(%MediaItem{} = media_item, provider_id, media_type, source, config) do
    fetch_opts = [
      media_type: media_type,
      provider: source,
      append_to_response: Metadata.default_append_to_response(media_type),
      season_order: media_item.season_order
    ]

    Metadata.fetch_by_id(config, to_string(provider_id), fetch_opts)
  end

  # `source` is threaded in from the resolution that actually produced
  # `metadata`, never re-derived from the pre-update struct. Re-deriving is what
  # let a recovered id get written to the wrong column.
  defp apply_metadata(media_item, metadata, source) do
    attrs =
      %{
        title: metadata.title,
        original_title: metadata.original_title,
        year: extract_year(metadata),
        imdb_id: metadata.imdb_id,
        metadata: metadata
      }
      |> put_provider_id(source, metadata.id)
      |> ExternalIds.put_free_ids(metadata.external_ids,
        exclude_id: media_item.id,
        title: metadata.title
      )

    case Media.update_media_item(Scope.system(), media_item, attrs, reason: "Metadata refreshed") do
      {:ok, updated} ->
        {:ok, updated}

      {:error, changeset} ->
        Logger.error("Failed to update media item during refresh",
          media_item_id: media_item.id,
          errors: inspect(changeset.errors)
        )

        {:error, :update_failed}
    end
  end

  defp put_provider_id(attrs, _source, nil), do: attrs
  defp put_provider_id(attrs, :tvdb, id), do: Map.put(attrs, :tvdb_id, id)
  defp put_provider_id(attrs, _source, id), do: Map.put(attrs, :tmdb_id, id)

  # Episode refresh is best-effort: every other caller already ignores its
  # result, and a failed episode fetch must not fail an otherwise good metadata
  # refresh. Log it so the failure is still visible.
  # `config` is threaded through rather than re-derived: refresh_episodes_for_tv_show/2
  # falls back to Metadata.default_relay_config/0, so dropping it here sent the
  # episode leg of an injected-config refresh at the real relay.
  defp post_update(updated, :tv_show, true, config, opts) do
    force = Keyword.get(opts, :force, false)

    case Media.refresh_episodes_for_tv_show(updated, config: config, force: force) do
      {:ok, _count} ->
        :ok

      {:error, reason} ->
        Logger.warning("Metadata refreshed but episode refresh failed",
          media_item_id: updated.id,
          reason: inspect(reason)
        )
    end

    NfoWriter.maybe_write_nfos(updated)
    :ok
  end

  defp post_update(updated, _media_type, _fetch_episodes, _config, _opts) do
    NfoWriter.maybe_write_nfos(updated)
    :ok
  end

  defp extract_year(%MediaMetadata{release_date: %Date{} = date}), do: date.year
  defp extract_year(%MediaMetadata{first_air_date: %Date{} = date}), do: date.year
  defp extract_year(%MediaMetadata{}), do: nil

  @doc """
  Resolves which provider and id a refresh should fetch from.

  `metadata_source` is the authoritative provenance recorded when an item was
  matched under per-library provider selection, so it wins even when a
  back-filled id for the other provider is also present. Only when it is absent
  do we fall back to the legacy TVDB-precedence rule, and only after that to the
  id stored inside the metadata blob.

  Returns the id as an **integer**. Callers building an HTTP path convert with
  `to_string/1`.
  """
  @spec resolve_provider(MediaItem.t()) :: resolution()
  def resolve_provider(%MediaItem{metadata_source: :tmdb, tmdb_id: id}) when not is_nil(id),
    do: {id, :tmdb}

  def resolve_provider(%MediaItem{metadata_source: :tvdb, tvdb_id: id}) when not is_nil(id),
    do: {id, :tvdb}

  def resolve_provider(%MediaItem{tvdb_id: id}) when not is_nil(id), do: {id, :tvdb}
  def resolve_provider(%MediaItem{tmdb_id: id}) when not is_nil(id), do: {id, :tmdb}

  def resolve_provider(%MediaItem{metadata: %MediaMetadata{} = metadata} = media_item) do
    case normalize_id(metadata.id) || normalize_id(metadata.provider_id) do
      nil -> {nil, nil}
      id -> {id, stored_blob_provider(media_item, metadata)}
    end
  end

  def resolve_provider(%MediaItem{}), do: {nil, nil}

  # Which provider issued the id stored inside the metadata blob.
  #
  # The blob records its own provenance: `Relay.fetch_tvdb_by_id/3` stamps
  # `provider: :tvdb`, while the TMDB path leaves the
  # `MediaMetadata.from_api_response/3` default of `:metadata_relay`. Assuming
  # `:tmdb` unconditionally (as the old duplicated resolvers did) routes a TVDB
  # id to `/tmdb/tv/shows/<tvdb-id>` and fetches an unrelated title.
  #
  # `metadata_source` still outranks the blob when set, since it is the
  # authoritative provenance recorded at match time.
  defp stored_blob_provider(%MediaItem{metadata_source: source}, _metadata)
       when source in [:tvdb, :tmdb],
       do: source

  defp stored_blob_provider(_media_item, %MediaMetadata{provider: :tvdb}), do: :tvdb
  defp stored_blob_provider(_media_item, %MediaMetadata{}), do: :tmdb

  # Struct field access, never Access syntax. `provider_id` is frequently the
  # empty string because `MetadataType.map_to_struct/1` defaults it to
  # `to_string(data[:id] || "")`, and "" is truthy in Elixir.
  defp normalize_id(id) when is_integer(id), do: id

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp normalize_id(_), do: nil
end
