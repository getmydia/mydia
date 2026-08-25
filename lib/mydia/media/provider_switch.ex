defmodule Mydia.Media.ProviderSwitch do
  @moduledoc """
  Provider-aware refresh for TV shows: deciding whether a refresh should re-fetch
  from the show's current provider or re-identify it against a different one, and
  safely reconciling episodes when the provider changes.

  This is the read side (`resolve_library_provider/1`, `provider_refresh_decision/1`,
  `find_reidentify_candidate/3`) plus the destructive switch
  (`adopt_provider_switch/4`). It calls back into `Mydia.Media` for shared
  persistence and scoring helpers.
  """

  import Ecto.Query, warn: false

  alias Mydia.Accounts.Scope
  alias Mydia.Media
  alias Mydia.Media.{Episode, MediaItem}
  alias Mydia.Library.MediaFile
  alias Mydia.Repo

  @doc """
  Resolves the TV metadata provider configured for the libraries a show lives in.

  A show's files may be linked directly (`media_files.media_item_id`) or through
  episodes (`episodes -> media_files`); both paths are considered. Returns:

    * `{:ok, :tvdb | :tmdb}` - all of the show's series/mixed libraries agree
    * `:ambiguous` - libraries disagree on the provider
    * `:none` - the show is not in any series/mixed library
  """
  @spec resolve_library_provider(MediaItem.t()) :: {:ok, atom()} | :ambiguous | :none
  def resolve_library_provider(%MediaItem{} = media_item) do
    case media_item |> library_providers_for_item() |> Enum.uniq() do
      [] -> :none
      [single] -> {:ok, single}
      _ -> :ambiguous
    end
  end

  defp library_providers_for_item(%MediaItem{id: id}) do
    direct =
      from mf in MediaFile,
        join: lp in Mydia.Settings.LibraryPath,
        on: mf.library_path_id == lp.id,
        where: mf.media_item_id == ^id and lp.type in [:series, :mixed],
        select: lp.tv_metadata_source,
        distinct: true

    episodic =
      from mf in MediaFile,
        join: lp in Mydia.Settings.LibraryPath,
        on: mf.library_path_id == lp.id,
        join: e in Episode,
        on: mf.episode_id == e.id,
        where: e.media_item_id == ^id and lp.type in [:series, :mixed],
        select: lp.tv_metadata_source,
        distinct: true

    (Repo.all(direct) ++ Repo.all(episodic)) |> Enum.reject(&is_nil/1)
  end

  @doc """
  Decides whether a TV show refresh should re-fetch from its current provider or
  re-identify against a different one.

  Returns `:refetch` when the show's library provider matches the stored
  `metadata_source` (or is unknown/ambiguous), or `{:reidentify, target}` when
  the library provider differs and the show should be re-identified against
  `target`.
  """
  @spec provider_refresh_decision(MediaItem.t()) :: :refetch | {:reidentify, atom()}
  def provider_refresh_decision(%MediaItem{type: "tv_show"} = media_item) do
    case resolve_library_provider(media_item) do
      {:ok, lib_provider} ->
        cond do
          is_nil(media_item.metadata_source) -> :refetch
          media_item.metadata_source == lib_provider -> :refetch
          true -> {:reidentify, lib_provider}
        end

      # Ambiguous or no library: behave as a same-provider re-fetch.
      _ ->
        :refetch
    end
  end

  def provider_refresh_decision(%MediaItem{}), do: :refetch

  @doc """
  Searches the target provider for a show and decides whether the best match is
  confident enough to adopt automatically.

  Read-only: this does not mutate the item. Returns:

    * `{:confident, %SearchResult{}}` - near-exact title and matching year; the
      caller may adopt it via `adopt_provider_switch/4`
    * `{:needs_picker, [%SearchResult{}]}` - ranked candidates for a manual pick
    * `{:error, reason}` - search failed
  """
  @spec find_reidentify_candidate(MediaItem.t(), atom(), map() | nil) ::
          {:confident, struct()} | {:needs_picker, [struct()]} | {:error, term()}
  def find_reidentify_candidate(%MediaItem{} = media_item, target_provider, config \\ nil) do
    config = config || Mydia.Metadata.default_relay_config()

    base_opts = [media_type: :tv_show, provider: target_provider]
    search_opts = if media_item.year, do: [{:year, media_item.year} | base_opts], else: base_opts

    case Mydia.Metadata.search(config, media_item.title, search_opts) do
      {:ok, results} when results != [] ->
        rank_reidentify_candidates(results, media_item)

      {:ok, []} when not is_nil(media_item.year) ->
        # Retry without the year filter before giving up.
        case Mydia.Metadata.search(config, media_item.title, base_opts) do
          {:ok, results} when results != [] -> rank_reidentify_candidates(results, media_item)
          {:ok, []} -> {:needs_picker, []}
          {:error, reason} -> {:error, reason}
        end

      {:ok, []} ->
        {:needs_picker, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp rank_reidentify_candidates(results, media_item) do
    ranked =
      results
      |> Enum.map(fn result ->
        {result, Media.calculate_title_match_score(result, media_item)}
      end)
      |> Enum.sort_by(fn {_result, score} -> score end, :desc)
      |> Enum.map(fn {result, _score} -> result end)

    best = List.first(ranked)

    if best && confident_reidentify_match?(best, media_item) do
      {:confident, best}
    else
      {:needs_picker, ranked}
    end
  end

  # Conservative gate for the silent, destructive auto-adopt. A confident match
  # WIPES the show's episodes and per-episode watch history with no operator
  # confirmation, so title + year alone is not enough: a remake/reboot that
  # shares a title and (within 1) year would silently destroy the original
  # show's state. We therefore require an additional imdb_id corroboration -
  # both sides must carry the same canonical imdb id (e.g. "tt0903747"). When
  # either imdb_id is missing or they differ, the match is NOT confident and
  # falls through to the manual picker so the operator confirms the switch.
  defp confident_reidentify_match?(candidate, media_item) do
    not is_nil(media_item.year) and not is_nil(candidate.year) and
      Media.exact_title_match?(candidate.title, media_item.title) and
      Media.year_matches?(candidate.year, media_item.year) and
      imdb_ids_corroborate?(media_item.imdb_id, candidate.imdb_id)
  end

  # imdb ids are canonical identifiers, so an exact string match is sufficient
  # corroboration. Both sides must be present (non-nil, non-empty).
  defp imdb_ids_corroborate?(item_imdb_id, candidate_imdb_id) do
    present?(item_imdb_id) and present?(candidate_imdb_id) and
      to_string(item_imdb_id) == to_string(candidate_imdb_id)
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  @doc """
  Switches a TV show to a different metadata provider and reconciles its episodes.

  Safe by construction:

    * The new provider's show metadata and all season episode data are fetched
      and validated **before** anything is deleted, so a failed/empty fetch
      leaves the show's existing episodes untouched (it is never left
      episode-less).
    * The destructive swap (delete old episodes, set the new provider id, clear
      the old one, recreate episodes from the pre-fetched data, re-link files)
      runs in a single `Repo.transaction` with no network calls inside it.
    * Files are captured before the wipe and re-stamped with `media_item_id` so
      `match_files_to_episodes/1` can re-link them by filename. Files that no
      longer parse to a known episode stay attached to the show rather than
      orphaned.

  Episode-level watch progress and download history reference episodes with
  `ON DELETE SET NULL`, so a switch resets that per-episode state (the caller is
  expected to warn the operator).

  Returns `{:ok, media_item}` with the reconciled show, or `{:error, reason}`
  (leaving existing data intact on failure).
  """
  @spec adopt_provider_switch(MediaItem.t(), struct(), atom(), map() | nil) ::
          {:ok, MediaItem.t()} | {:error, term()}
  def adopt_provider_switch(media_item, candidate, target_provider, config \\ nil)

  def adopt_provider_switch(
        %MediaItem{type: "tv_show"} = item,
        candidate,
        target_provider,
        config
      ) do
    config = config || Mydia.Metadata.default_relay_config()
    new_id = to_string(candidate.provider_id)

    # Step 1 + 2 (no mutation): validate the new show metadata and pre-fetch all
    # season episode data into memory.
    #
    # No `season_order:` is threaded, and that is the decision rather than an
    # omission: a provider switch re-identifies the show, so the new provider's
    # official ordering is the only one that can mean anything here.
    #
    #   * An ordering is a choice about one series record. This replaces that
    #     record, so the old choice describes seasons that are no longer the
    #     show's -- including TVDB-to-TVDB, where the new series id has its own
    #     DVD ordering covering its own seasons.
    #   * Only TVDB has parallel orderings at all. Carrying `:dvd` into a TMDB
    #     switch would ask for something TMDB cannot answer.
    #   * There is nothing to remap onto anyway. `SeasonOrder.remap/3` is
    #     lossless because it renumbers rows in place; this path deletes every
    #     episode row and recreates it, so the identity a remap keys on is gone
    #     before an ordering could be applied.
    #
    # `provider_switch_attrs/3` clears `season_order` to match, which puts the
    # show back at "never asked" and lets the suggestion banner re-offer the
    # new provider's alternative ordering if it has one.
    with {:ok, metadata} <-
           Mydia.Metadata.fetch_by_id(config, new_id,
             media_type: :tv_show,
             provider: target_provider,
             append_to_response: Mydia.Metadata.default_append_to_response(:tv_show)
           ),
         {:ok, season_datas, expected_episode_count} <-
           prefetch_provider_seasons(
             new_id,
             target_provider,
             metadata.seasons || [],
             config,
             metadata.original_language
           ) do
      # Step 3 (transactional, no network): wipe + swap + recreate + re-link.
      result =
        Repo.transaction(fn ->
          file_ids = linked_media_file_ids(item)

          # Season monitoring lives in the episode rows, so the wipe below
          # erases it. Capture the per-season verdict first and replay it, or
          # every season the user deliberately unmonitored comes back monitored
          # under the show's new-season default.
          # Folded in Elixir rather than aggregated in SQL: PostgreSQL has a
          # real boolean type and refuses `max(cast(bool as int))`, while SQLite
          # stores booleans as integers and accepts it. One portable query beats
          # branching on the adapter.
          monitored_by_season =
            from(e in Episode,
              where: e.media_item_id == ^item.id,
              select: {e.season_number, e.monitored}
            )
            |> Repo.all()
            |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
            |> Map.new(fn {season_number, flags} -> {season_number, Enum.any?(flags)} end)

          Repo.delete_all(from(e in Episode, where: e.media_item_id == ^item.id))

          # Roll back (preserving the just-deleted episodes) instead of raising a
          # MatchError if the new provider id collides with another show's
          # unique constraint — the caller expects {:error, reason}, not a crash.
          updated =
            case Media.update_media_item(
                   Scope.system(),
                   item,
                   provider_switch_attrs(target_provider, new_id, metadata),
                   reason: "Provider switched to #{target_provider}"
                 ) do
              {:ok, updated} -> updated
              {:error, changeset} -> Repo.rollback({:provider_switch_update_failed, changeset})
            end

          Enum.each(season_datas, fn season_data ->
            monitor_new? =
              case Map.fetch(monitored_by_season, season_data.season_number) do
                # A season the show already had keeps whatever the user decided.
                {:ok, was_monitored?} -> was_monitored?
                # Genuinely new to this provider, so the normal rule applies.
                :error -> Media.should_monitor_new_episode?(updated, season_data.season_number)
              end

            Media.upsert_episodes_from_season(updated, season_data, monitor_new?: monitor_new?)
          end)

          # `upsert_episodes_from_season/3` swallows per-episode insert errors
          # (e.g. a duplicate episode_number hitting the unique constraint, or a
          # malformed payload), so the recreation can silently persist FEWER
          # episodes than were fetched. Since the old episodes are already
          # deleted at this point, that would be silent data loss. Verify the
          # persisted count against the expected total and roll the whole switch
          # back if episodes went missing, preserving the original episodes.
          actual_episode_count =
            Repo.aggregate(from(e in Episode, where: e.media_item_id == ^updated.id), :count, :id)

          if actual_episode_count < expected_episode_count do
            Repo.rollback(
              {:incomplete_episode_recreation, expected_episode_count, actual_episode_count}
            )
          end

          # Only now are the seasons genuinely refreshed from the new provider.
          # Inside the transaction, so a later rollback takes the stamp with it.
          Media.stamp_seasons_refreshed(updated)

          # Re-attach captured files to the show so re-linking can find them,
          # then re-link by filename. Files that don't parse stay on the show.
          Repo.update_all(
            from(mf in MediaFile, where: mf.id in ^file_ids),
            set: [media_item_id: updated.id, episode_id: nil]
          )

          Mydia.Library.match_files_to_episodes(updated.id)

          Media.get_media_item!(Scope.system(), updated.id)
        end)

      case result do
        {:ok, reconciled} -> {:ok, reconciled}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def adopt_provider_switch(%MediaItem{type: type}, _candidate, _target, _config) do
    {:error, {:invalid_type, "Expected tv_show, got #{type}"}}
  end

  defp prefetch_provider_seasons(provider_id, target_provider, seasons, config, original_language) do
    has_tvdb = target_provider == :tvdb

    # All-or-nothing: abort the whole switch if ANY season fails to fetch. A
    # transient relay error must never let the caller delete the show's existing
    # episodes and recreate only the subset that happened to fetch successfully.
    result =
      Enum.reduce_while(seasons, {:ok, []}, fn season, {:ok, acc} ->
        season_fetch_opts =
          if has_tvdb do
            # A TVDB-target season with no tvdb_season_id would route to the TMDB
            # endpoint with a TVDB id (wrong data / 404), so treat it as a hard
            # failure rather than silently fetching from the wrong provider.
            case Map.get(season, :tvdb_season_id) do
              nil ->
                :error

              tvdb_season_id ->
                opts =
                  [tvdb_season_id: tvdb_season_id, original_language: original_language]
                  |> Enum.reject(fn {_key, value} -> is_nil(value) end)

                {:ok, opts}
            end
          else
            {:ok, []}
          end

        case season_fetch_opts do
          :error ->
            {:halt, {:error, {:missing_tvdb_season_id, season.season_number}}}

          {:ok, opts} ->
            case Mydia.Metadata.fetch_season_cached(
                   config,
                   to_string(provider_id),
                   season.season_number,
                   opts
                 ) do
              {:ok, season_data} ->
                {:cont, {:ok, [season_data | acc]}}

              {:error, reason} ->
                {:halt, {:error, {:season_fetch_failed, season.season_number, reason}}}
            end
        end
      end)

    with {:ok, season_datas} <- result do
      season_datas = Enum.reverse(season_datas)

      total_episodes =
        Enum.reduce(season_datas, 0, fn sd, acc -> acc + length(sd.episodes || []) end)

      if total_episodes > 0,
        do: {:ok, season_datas, total_episodes},
        else: {:error, :no_episodes}
    end
  end

  defp linked_media_file_ids(%MediaItem{id: id}) do
    episode_linked =
      from mf in MediaFile,
        join: e in Episode,
        on: mf.episode_id == e.id,
        where: e.media_item_id == ^id,
        select: mf.id

    direct =
      from mf in MediaFile,
        where: mf.media_item_id == ^id,
        select: mf.id

    (Repo.all(episode_linked) ++ Repo.all(direct)) |> Enum.uniq()
  end

  # seasons_refreshed_at is deliberately absent: it is not castable, so passing
  # it here was a silent no-op. Media.stamp_seasons_refreshed/1 sets it once the
  # switch has actually re-seeded the episodes.
  #
  # season_order: nil resets whatever TVDB ordering the user had picked.
  # Re-identifying against a new provider recreates every episode at the new
  # provider's official coordinates, so "which ordering did the user pick"
  # stops meaning anything the old provider's ids described — nil correctly
  # means "never asked" again, rather than leaving a stale ordering that a
  # later refresh would try (and partially fail) to reconcile toward.
  defp provider_switch_attrs(:tvdb, new_id, metadata) do
    %{
      tvdb_id: String.to_integer(new_id),
      tmdb_id: nil,
      metadata_source: :tvdb,
      metadata: metadata,
      season_order: nil
    }
  end

  defp provider_switch_attrs(:tmdb, new_id, metadata) do
    %{
      tmdb_id: String.to_integer(new_id),
      tvdb_id: nil,
      metadata_source: :tmdb,
      metadata: metadata,
      season_order: nil
    }
  end
end
