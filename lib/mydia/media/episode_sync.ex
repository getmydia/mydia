defmodule Mydia.Media.EpisodeSync do
  @moduledoc """
  Owns syncing a TV show's seasons and episodes from the metadata provider:
  the throttled full refresh, the targeted per-season refresh and the episode upsert.
  """

  import Ecto.Query, warn: false
  require Logger
  alias Mydia.Repo
  alias Mydia.Accounts.Scope
  alias Mydia.Media.{Episode, EpisodePlaceholder, Episodes, MediaItem, Monitoring, TitleMatch}
  alias Mydia.Metadata.Access, as: MetadataAccess
  alias Mydia.Events

  @doc """
  Refreshes episodes for a TV show by fetching metadata and creating missing episodes.

  This function is useful for:
  - TV shows added before season metadata was included
  - Manually refreshing episodes when new seasons are available
  - Fixing TV shows with missing episode data

  ## Parameters
    - `media_item` - The TV show media item (must be type "tv_show")
    - `opts` - Options for episode creation
      - `:config` - Metadata relay config. Defaults to `Metadata.default_relay_config/0`.
        Callers that inject a Bypass (or any non-default relay) must pass it;
        otherwise the refresh silently uses the global default.
      - `:force` - Fetch even when `seasons_refreshed_at` is inside the throttle
        window. Defaults to `false`. Pass it whenever a person asked for this
        show specifically; leave it off for sweeps. See
        `should_skip_season_refresh?/1`.
      - `:actor_type` / `:actor_id` - Recorded on the
        `media_item.episode_titles_updated` event when a title changed.
        Default `:system` / `"media_context"`.

  ## Returns
    - `{:ok, count}` - Number of episodes created
    - `{:error, reason}` - Error reason

  ## Examples

      iex> refresh_episodes_for_tv_show(media_item)
      {:ok, 236}
  """
  @spec refresh_episodes_for_tv_show(MediaItem.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def refresh_episodes_for_tv_show(media_item, opts \\ [])

  def refresh_episodes_for_tv_show(%MediaItem{type: "tv_show"} = media_item, opts) do
    alias Mydia.Metadata

    # Honour an injected relay config (Bypass in tests, or a caller-specific
    # relay). Ignoring opts[:config] silently falls back to the global default
    # and was the root of the MediaAddHelpers CI timeout flake: the Bypass
    # stubs covered the add-path fetch, then create_media_item refreshed
    # against the real relay with Task.async_stream timeout: :infinity.
    config = Keyword.get(opts, :config) || Metadata.default_relay_config()

    # Resolve the provider to fetch from. `metadata_source` (when set) is the
    # authoritative provenance; only fall back to the legacy TVDB-precedence
    # rule and the stored metadata provider_id when it is absent.
    # Refresh.resolve_provider/1 already includes the stored-metadata fallback,
    # reading struct fields rather than string keys. (The old fallback here
    # matched %{"provider_id" => id} against an atom-keyed %MediaMetadata{} and
    # could never fire.) It returns an integer id; this function threads
    # provider ids as strings.
    {provider_id, provider_source} =
      case Mydia.Media.Refresh.resolve_provider(media_item) do
        {nil, nil} -> {nil, nil}
        {id, source} -> {to_string(id), source}
      end

    # If we have a TMDB ID but no TVDB ID, try to discover the TVDB ID so we can
    # use the preferred TVDB provider for TV shows. Skip this when the show has
    # an explicit `metadata_source` — a TMDB-sourced show must not be silently
    # switched to TVDB on refresh.
    {provider_id, provider_source, media_item} =
      if provider_source == :tmdb and is_nil(media_item.tvdb_id) and
           is_nil(media_item.metadata_source) do
        maybe_discover_tvdb_id(media_item, provider_id, config)
      else
        {provider_id, provider_source, media_item}
      end

    # If no provider ID, try to recover it by searching by title
    {provider_id, provider_source, media_item} =
      if is_nil(provider_id) or provider_id == "" do
        case TitleMatch.do_recover_provider_id_by_title(media_item, :tv_show, config) do
          {:ok, recovered_id, updated_item} ->
            # Recovery searches TVDB for TV shows
            source = if updated_item.tvdb_id, do: :tvdb, else: :tmdb
            {to_string(recovered_id), source, updated_item}

          {:error, _reason} ->
            {nil, nil, media_item}
        end
      else
        {provider_id, provider_source, media_item}
      end

    if is_nil(provider_id) or provider_id == "" do
      {:error, :missing_provider_id}
    else
      # Check if we should skip season refresh based on threshold
      if not Keyword.get(opts, :force, false) and should_skip_season_refresh?(media_item) do
        Logger.info(
          "Skipping season refresh for #{media_item.title} - recently refreshed at #{media_item.seasons_refreshed_at}"
        )

        # Count existing episodes instead
        episode_count =
          Episode
          |> where([e], e.media_item_id == ^media_item.id)
          |> Repo.aggregate(:count)

        {:ok, episode_count}
      else
        # `season_order` selects which of TVDB's parallel orderings the seasons
        # list describes. Without it the column is inert: a show switched to the
        # DVD ordering would refetch the official one and drift straight back to
        # a single 170-episode season. nil resolves to "official" inside
        # SeasonOrder.tvdb_type/1, so passing it through unguarded is correct.
        ref = {provider_source, String.to_integer(provider_id)}

        case Metadata.fetch_by_ref(config, ref,
               media_type: :tv_show,
               season_order: media_item.season_order
             ) do
          {:ok, metadata} ->
            # Get seasons from metadata struct
            seasons = metadata.seasons || []

            Logger.info(
              "Fetching episodes for TV show: #{media_item.title}, found #{length(seasons)} seasons in metadata"
            )

            # Invalidate season cache to ensure fresh data with translations
            Enum.each(seasons, &invalidate_season_cache(media_item, provider_id, &1))

            # Fetch and create episodes for each season. Track failures: the
            # timestamp below throttles the next refresh, so stamping it after a
            # partial pass would hide the seasons that failed until the
            # threshold expires.
            {episode_count, failed_seasons, title_changes} =
              Enum.reduce_while(seasons, {0, 0, []}, fn season, {count, failed, changes} ->
                Logger.info("Processing episodes for season #{season.season_number}")

                case create_episodes_for_season(media_item, season, config) do
                  {:ok, created, season_changes} ->
                    Logger.info(
                      "Processed #{created} episodes for season #{season.season_number}"
                    )

                    {:cont, {count + created, failed, changes ++ season_changes}}

                  # An ordering switch or a provider switch landed while this
                  # pass was fetching. Every season still to come was fetched
                  # against the same now-stale show, so stop rather than log
                  # one error per remaining season. Counting it as a failure
                  # is what leaves `seasons_refreshed_at` unstamped, which is
                  # what makes the next refresh re-fetch against the show as
                  # it actually is now.
                  {:error, :refresh_target_changed, _season_changes} ->
                    Logger.warning(
                      "Aborting season refresh: show changed mid-refresh",
                      media_item_id: media_item.id
                    )

                    {:halt, {count, failed + 1, changes}}

                  {:error, reason, season_changes} ->
                    Logger.error(
                      "Failed to create episodes for season #{season.season_number}: #{inspect(reason)}"
                    )

                    {:cont, {count, failed + 1, changes ++ season_changes}}
                end
              end)

            Logger.info("Total episodes processed: #{episode_count}")

            record_title_changes(media_item, title_changes, opts)

            if failed_seasons > 0 do
              Logger.warning(
                "Not stamping seasons_refreshed_at: #{failed_seasons} season(s) failed",
                media_item_id: media_item.id
              )
            else
              stamp_seasons_refreshed(media_item)
            end

            {:ok, episode_count}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  def refresh_episodes_for_tv_show(%MediaItem{type: type}, _opts) do
    {:error, {:invalid_type, "Expected tv_show, got #{type}"}}
  end

  @doc """
  Re-reads only the named seasons of a TV show from its provider.

  Narrower than `refresh_episodes_for_tv_show/2` on purpose, because
  `Mydia.Jobs.AiringEpisodeRefresh` calls it several times a day:

    * It never fetches the show. Each season's `tvdb_season_id` comes from the
      seasons stored in `media_item.metadata`, and a season missing there is
      skipped.
    * It never attempts title recovery. A show without a provider id returns
      `{:error, :missing_provider_id}` and is left to the weekly pass.
    * It does not update the media item row, stamp `seasons_refreshed_at`, or
      consult the season throttle.

  When an episode title changed it records one
  `media_item.episode_titles_updated` event and rewrites exported NFOs.

  ## Options
    - `:config` - Metadata relay config. Defaults to `Metadata.default_relay_config/0`.
    - `:actor_type` / `:actor_id` - Recorded on the title-change event.
      Default `:system` / `"media_context"`.

  ## Returns
    - `{:ok, title_changes}` - every named season refreshed or was skipped
    - `{:error, {:failed_seasons, count}}` - at least one season failed; title
      changes from the seasons that succeeded are still recorded
    - `{:error, :missing_provider_id}`
  """
  @spec refresh_seasons(MediaItem.t(), [non_neg_integer()], keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def refresh_seasons(media_item, season_numbers, opts \\ [])

  def refresh_seasons(%MediaItem{type: "tv_show"} = media_item, season_numbers, opts) do
    config = Keyword.get(opts, :config) || Mydia.Metadata.default_relay_config()

    case Mydia.Media.Refresh.resolve_provider(media_item) do
      {nil, _source} ->
        {:error, :missing_provider_id}

      {provider_id, _source} ->
        stored_seasons = stored_seasons_by_number(media_item)

        {title_changes, failed} =
          Enum.reduce(season_numbers, {[], 0}, fn season_number, {changes, failed} ->
            case Map.fetch(stored_seasons, season_number) do
              {:ok, season} ->
                invalidate_season_cache(media_item, to_string(provider_id), season)

                case create_episodes_for_season(media_item, season, config) do
                  {:ok, _count, season_changes} ->
                    {changes ++ season_changes, failed}

                  {:error, reason, season_changes} ->
                    Logger.warning("Season refresh failed",
                      media_item_id: media_item.id,
                      season_number: season_number,
                      reason: inspect(reason)
                    )

                    {changes ++ season_changes, failed + 1}
                end

              :error ->
                Logger.warning("Season missing from stored metadata, skipping refresh",
                  media_item_id: media_item.id,
                  season_number: season_number
                )

                {changes, failed}
            end
          end)

        record_title_changes(media_item, title_changes, opts)

        if title_changes != [] do
          Mydia.Metadata.NfoWriter.maybe_write_nfos(media_item)
        end

        if failed > 0, do: {:error, {:failed_seasons, failed}}, else: {:ok, title_changes}
    end
  end

  def refresh_seasons(%MediaItem{type: type}, _season_numbers, _opts) do
    {:error, {:invalid_type, "Expected tv_show, got #{type}"}}
  end

  @doc """
  Records that a show's seasons were successfully refreshed.

  Writes straight to the column rather than through `changeset/2`, matching
  `Upgrades.stamp_checked/2`. This field is owned by the refresh machinery and
  gates `should_skip_season_refresh?/1`, so it must not be mass-assignable from
  attrs a caller controls. Routing it through `update_media_item/3` is what
  silently dropped every write before, since `changeset/2` does not cast it.
  """
  @spec stamp_seasons_refreshed(MediaItem.t()) :: {non_neg_integer(), nil}
  def stamp_seasons_refreshed(%MediaItem{id: id}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    MediaItem
    |> where([m], m.id == ^id)
    |> Repo.update_all(set: [seasons_refreshed_at: now])
  end

  # Deletes a season's Mydia-side cache entry so the next fetch goes to the
  # relay. Uses the configured language so the deleted key matches the one
  # fetch_season_by_ref_cached/4 writes under.
  defp invalidate_season_cache(media_item, provider_id, season) do
    tvdb_season_id =
      if is_nil(media_item.tvdb_id), do: nil, else: Map.get(season, :tvdb_season_id)

    provider_id
    |> Mydia.Metadata.build_season_cache_key(
      season.season_number,
      Mydia.Metadata.metadata_language(),
      tvdb_season_id
    )
    |> Mydia.Metadata.Cache.delete()
  end

  # One event per refresh, never one per season, and none when nothing
  # changed: re-reading identical titles must stay out of the activity feed.
  defp record_title_changes(_media_item, [], _opts), do: :ok

  defp record_title_changes(media_item, title_changes, opts) do
    Events.episode_titles_updated(
      media_item,
      title_changes,
      Keyword.get(opts, :actor_type, :system),
      Keyword.get(opts, :actor_id, "media_context")
    )
  end

  defp stored_seasons_by_number(%MediaItem{
         metadata: %Mydia.Metadata.Structs.MediaMetadata{seasons: seasons}
       })
       when is_list(seasons) do
    Map.new(seasons, &{&1.season_number, &1})
  end

  defp stored_seasons_by_number(%MediaItem{}), do: %{}

  @doc """
  Upserts episodes from season data into the database.

  Creates new episodes or updates existing ones with fresh metadata from the
  provider. This is the single source of truth for episode creation/update
  from season data — all callers should use this instead of duplicating logic.

  ## Options
    - `:monitor_new?` - Required boolean. Whether newly created episodes arrive
      monitored. Compute it once per season with `should_monitor_new_episode?/2`.
  ## Returns
    - `{:ok, count}` - Number of episodes processed (created + updated)
  """
  @spec upsert_episodes_from_season(MediaItem.t(), struct(), keyword()) ::
          {:ok, non_neg_integer()}
  def upsert_episodes_from_season(media_item, season_data, opts \\ []) do
    # Required on purpose. A default here is what let the scanner and enricher
    # drift into monitoring everything regardless of the show's intent.
    monitor_new? = Keyword.fetch!(opts, :monitor_new?)

    {count, _title_changes} = upsert_season_episodes(media_item, season_data, monitor_new?)
    {:ok, count}
  end

  # The body of upsert_episodes_from_season/3, also returning the title changes
  # it wrote so a refresh can report them. The public function keeps its
  # {:ok, count} contract for the scanner, enricher and provider switch, none of
  # which report titles.
  defp upsert_season_episodes(media_item, season_data, monitor_new?) do
    episodes = season_data.episodes || []

    {count, title_changes} =
      Enum.reduce(episodes, {0, []}, fn episode, {count, title_changes} = acc ->
        season_num = episode.season_number
        episode_num = episode.episode_number

        # Skip if season or episode number is nil
        if is_nil(season_num) or is_nil(episode_num) do
          acc
        else
          existing = find_existing_episode(media_item.id, episode)

          air_date = parse_air_date(episode.air_date)

          if is_nil(existing) do
            case Episodes.create_episode(%{
                   media_item_id: media_item.id,
                   season_number: season_num,
                   episode_number: episode_num,
                   absolute_number: episode.absolute_number,
                   provider_episode_id: episode.provider_episode_id,
                   title: episode.name,
                   air_date: air_date,
                   metadata: Map.from_struct(episode),
                   monitored: monitor_new?
                 }) do
              {:ok, _episode} -> {count + 1, title_changes}
              {:error, _changeset} -> acc
            end
          else
            # Update existing episode with fresh metadata. Season/episode
            # number are included because the lookup is now keyed on
            # provider_episode_id when present — a matched episode may
            # legitimately need to move to new coordinates (a reordering).
            #
            # `absolute_number`/`provider_episode_id` are written unguarded,
            # including when the incoming value is nil. Currently unreachable
            # for a tagged row in practice — the only way to reach the update
            # branch with a nil incoming provider_episode_id is via the
            # season/episode fallback, and `fallback_by_number/2` above only
            # ever hands back an *untagged* row when the incoming id is
            # present, or the untouched row otherwise — but nothing here
            # enforces it, so a future change to that matching logic could
            # silently start clearing a tagged row's id.
            case Episodes.update_episode(existing, %{
                   season_number: season_num,
                   episode_number: episode_num,
                   absolute_number: episode.absolute_number,
                   provider_episode_id: episode.provider_episode_id,
                   title: episode.name,
                   air_date: air_date,
                   metadata: Map.from_struct(episode)
                 }) do
              {:ok, _episode} ->
                {count + 1, maybe_add_title_change(title_changes, existing, episode)}

              {:error, _changeset} ->
                acc
            end
          end
        end
      end)

    {count, Enum.reverse(title_changes)}
  end

  defp maybe_add_title_change(title_changes, %Episode{title: old_title}, episode) do
    if EpisodePlaceholder.title_change?(old_title, episode.name) do
      change = %{
        season: episode.season_number,
        episode: episode.episode_number,
        old: old_title,
        new: episode.name
      }

      [change | title_changes]
    else
      title_changes
    end
  end

  # Provider episode id is the only identity stable across a season
  # reordering, so it wins when present. Without this, switching a show's
  # ordering inserts a parallel set of episodes and strands the originals,
  # along with their file links, watch history and monitored flags.
  #
  # Falls back to (season_number, episode_number) whenever the provider-id
  # lookup comes up empty — either because the incoming episode carries no
  # provider id (every TMDB-sourced show), or because it does but no row has
  # been tagged with it yet (every existing row until a backfill runs).
  # Skipping that second case would insert a duplicate row for the
  # not-yet-tagged episode at the very next refresh, colliding with the
  # (media_item_id, season_number, episode_number) unique index and failing
  # silently instead of updating the row in place.
  defp find_existing_episode(media_item_id, episode) do
    find_episode_by_provider_id(media_item_id, episode.provider_episode_id) ||
      fallback_by_number(media_item_id, episode)
  end

  defp find_episode_by_provider_id(_media_item_id, nil), do: nil

  defp find_episode_by_provider_id(media_item_id, provider_id) when is_binary(provider_id) do
    Repo.get_by(Episode, media_item_id: media_item_id, provider_episode_id: provider_id)
  end

  # No row currently carries the incoming provider id (or it has none). The
  # positional fallback is only safe to adopt when the row it finds is
  # untagged: an untagged row at these coordinates is very likely this same
  # episode, just not yet backfilled with an id. A row already tagged with a
  # *different* id is a different episode that happens to sit at the same
  # coordinates right now — adopting it would silently transfer that row's
  # identity (and its file links, watch history, monitored flag) onto the
  # incoming episode, which a later provider payload could permanently strand
  # at the wrong coordinates. Let that case fall through to create, where it
  # collides with the season/episode unique index and surfaces via the
  # {:incomplete_episode_upsert, ...} count check instead of doing this
  # silently.
  defp fallback_by_number(media_item_id, %{provider_episode_id: nil} = episode) do
    Episodes.get_episode_by_number(
      Scope.system(),
      media_item_id,
      episode.season_number,
      episode.episode_number
    )
  end

  defp fallback_by_number(media_item_id, episode) do
    case Episodes.get_episode_by_number(
           Scope.system(),
           media_item_id,
           episode.season_number,
           episode.episode_number
         ) do
      %Episode{provider_episode_id: nil} = untagged -> untagged
      _ -> nil
    end
  end

  defp create_episodes_for_season(media_item, season, config) do
    alias Mydia.Metadata

    # `metadata_source` (when set) is the authoritative provenance; only fall
    # back to the legacy TVDB-precedence rule and the stored-metadata
    # provider_id when it is absent. Mirrors the full-metadata refresh in
    # refresh_metadata/1 above, which resolves the same way for the same
    # reason: a TMDB-sourced show carrying a back-filled tvdb_id must not have
    # its episodes fetched from TVDB just because that id happens to exist.
    {provider_id, provider} =
      case Mydia.Media.Refresh.resolve_provider(media_item) do
        {nil, nil} -> {nil, nil}
        {id, source} -> {to_string(id), source}
      end

    has_tvdb = provider == :tvdb

    # Pass tvdb_season_id only if we have a tvdb_id (otherwise season IDs are TMDB).
    # Thread the show's original language so episode selection can fall back to it
    # before English, matching the enricher path.
    original_language = Metadata.LanguageCode.original_language_from(media_item.metadata)

    fetch_opts =
      if has_tvdb do
        [
          tvdb_season_id: Map.get(season, :tvdb_season_id),
          original_language: original_language
        ]
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      else
        []
      end

    ref = {provider, String.to_integer(provider_id)}

    case Metadata.fetch_season_by_ref_cached(
           config,
           ref,
           season.season_number,
           fetch_opts
         ) do
      {:ok, season_data} ->
        # Checked here, between the fetch and the write, rather than trusting
        # the struct the caller loaded. See `refresh_target_unchanged?/1`.
        if refresh_target_unchanged?(media_item) do
          upsert_season(media_item, season, season_data)
        else
          {:error, :refresh_target_changed, []}
        end

      {:error, reason} ->
        {:error, reason, []}
    end
  end

  defp upsert_season(media_item, season, season_data) do
    # upsert_episodes_from_season/3 swallows per-episode changeset errors and
    # still reports {:ok, count}, so a season can persist fewer episodes than
    # the provider returned and look clean. That must not stamp
    # seasons_refreshed_at, or the dropped episodes stay stale until the
    # throttle expires. Compare against what was actually upsertable.
    expected =
      Enum.count(
        season_data.episodes || [],
        &(not is_nil(&1.season_number) and not is_nil(&1.episode_number))
      )

    monitor_new? = Monitoring.should_monitor_new_episode?(media_item, season.season_number)

    case upsert_season_episodes(media_item, season_data, monitor_new?) do
      {count, title_changes} when count < expected ->
        # The episodes upserted before the count fell short are already
        # written, so any title change among them already landed in the
        # database. Report it rather than dropping it: the caller still
        # treats this as a failed season (so seasons_refreshed_at stays
        # unstamped), but the title changes it already collected are not lost.
        {:error, {:incomplete_episode_upsert, expected, count}, title_changes}

      {count, title_changes} ->
        {:ok, count, title_changes}
    end
  end

  # Whether the show is still the one the in-flight season data describes.
  #
  # A refresh reads the show once, fetches every season under it, then writes.
  # Two different mutations can commit in that gap, and the fetched payload is
  # wrong for the show afterwards either way:
  #
  #   * `SeasonOrder.switch/3` remaps the episodes onto another of TVDB's
  #     parallel orderings. Writing the old ordering's coordinates back mixes
  #     the two under a `season_order` column that claims one.
  #   * `ProviderSwitch.adopt_provider_switch/5` re-identifies the show
  #     entirely, deleting and recreating every episode against a different
  #     provider. Writing the old provider's episodes into that is worse:
  #     the coordinates and the provider ids both belong to a series this is
  #     no longer.
  #
  # So the comparison covers provenance, not just ordering. `season_order`
  # alone would miss the provider switch completely, because that path clears
  # `season_order` to nil -- and the overwhelmingly common case is a show that
  # was already nil, where nil == nil reads as unchanged.
  #
  # Both mutation paths hand this function a struct consistent with its row
  # (`Refresh.run/2` passes the `update_media_item/3` result;
  # `select_and_update_provider_id/3` returns the persisted item, or the
  # untouched one when the update failed), so this cannot decline a refresh
  # that merely updated the show on its way here.
  #
  # Re-reading immediately before the write narrows the window from every HTTP
  # fetch the refresh makes to the handful of statements between this check and
  # the upsert. It does not eliminate it: that would mean holding the show's
  # row for the duration of the writes, and a write transaction per season on
  # a hot path is a worse trade than a race that self-heals.
  defp refresh_target_unchanged?(%MediaItem{} = media_item) do
    %MediaItem{
      id: id,
      season_order: season_order,
      metadata_source: metadata_source,
      tvdb_id: tvdb_id,
      tmdb_id: tmdb_id
    } = media_item

    MediaItem
    |> where([m], m.id == ^id)
    |> select([m], {m.id, m.season_order, m.metadata_source, m.tvdb_id, m.tmdb_id})
    |> Repo.one()
    |> case do
      # Matched with the id included so that a deleted show reads as changed
      # rather than colliding with a live show whose every compared column is
      # legitimately NULL -- which `Repo.one/1` would otherwise answer with a
      # bare nil either way.
      {^id, ^season_order, ^metadata_source, ^tvdb_id, ^tmdb_id} -> true
      _ -> false
    end
  end

  defp parse_air_date(nil), do: nil
  defp parse_air_date(%Date{} = date), do: date

  defp parse_air_date(date_str) when is_binary(date_str) do
    case Date.from_iso8601(date_str) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_air_date(_), do: nil

  # Attempts to discover a TVDB ID for a TV show that only has a TMDB ID.
  # On success, updates the media item and switches to the TVDB provider.
  # On failure, returns the original TMDB provider info unchanged.
  defp maybe_discover_tvdb_id(%MediaItem{} = media_item, tmdb_provider_id, config) do
    Logger.info("Attempting TVDB discovery for TMDB-only TV show",
      media_item_id: media_item.id,
      title: media_item.title,
      tmdb_id: media_item.tmdb_id
    )

    case TitleMatch.do_recover_provider_id_by_title(media_item, :tv_show, config) do
      {:ok, recovered_id, updated_item} when not is_nil(updated_item.tvdb_id) ->
        Logger.info("Discovered TVDB ID for TV show",
          media_item_id: media_item.id,
          title: media_item.title,
          tvdb_id: updated_item.tvdb_id
        )

        {to_string(recovered_id), :tvdb, updated_item}

      _ ->
        # Discovery failed or didn't find a TVDB match — keep using TMDB
        {tmdb_provider_id, :tmdb, media_item}
    end
  end

  # Determines if we should skip refreshing season data based on the last refresh time
  defp should_skip_season_refresh?(%MediaItem{seasons_refreshed_at: nil}), do: false

  defp should_skip_season_refresh?(%MediaItem{} = media_item) do
    config = Mydia.Config.get()

    # Determine if show is completed/ended.
    #
    # Read through MetadataAccess: `metadata` is loaded as a %MediaMetadata{}
    # struct with atom keys, so the string-keyed match this used to do could
    # never succeed. `is_completed` was therefore always false and
    # completed_show_refresh_threshold_hours was never read — every ended show
    # was throttled as if it were still airing.
    is_completed =
      case MetadataAccess.get(media_item.metadata, :status) do
        status when is_binary(status) ->
          String.downcase(status) in ["ended", "canceled", "cancelled"]

        _ ->
          false
      end

    # Get appropriate threshold based on show status
    threshold_hours =
      if is_completed do
        config.media.completed_show_refresh_threshold_hours
      else
        config.media.season_refresh_threshold_hours
      end

    # Check if enough time has passed since last refresh
    now = DateTime.utc_now()
    threshold_seconds = threshold_hours * 3600
    diff = DateTime.diff(now, media_item.seasons_refreshed_at, :second)

    diff < threshold_seconds
  end
end
