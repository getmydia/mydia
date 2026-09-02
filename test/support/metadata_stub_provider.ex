defmodule Mydia.MetadataStubProvider do
  @moduledoc """
  Deterministic in-memory metadata provider for tests.

  Registered under `:metadata_relay` by `Mydia.MetadataStub.setup_metadata_stub/1`,
  which is the only seam that reaches both guest search and admin approval.
  `AdminRequestsLive.Index` calls `MediaRequests.approve_request/2` without a
  config, so injecting a Bypass config cannot cover the approval path.

  The catalog is deliberately tiny and self-consistent: every ref `search/3`
  implies is resolvable by `fetch_by_ref/3`, because approval re-fetches by
  that ref. A catalog that violates this reproduces the original defect, where
  the test seeded an id the relay had never heard of and the approval silently
  failed.

  The catalog is keyed by `Mydia.Metadata.Ref.t()`, not by a bare id: the
  series lives only under `{:tvdb, series_tvdb_id()}` and the movie only under
  `{:tmdb, movie_tmdb_id()}`. `{:tmdb, series_tvdb_id()}` is simply not in the
  catalog, so a caller that sends the series' TVDB id to the TMDB route misses
  naturally instead of getting an answer -- this is what let the Discover add
  bug ship three times, because the old id-keyed stub answered that pairing
  and made production's 404 invisible in tests.
  """

  @behaviour Mydia.Metadata.Provider

  alias Mydia.Metadata.Provider.Error
  alias Mydia.Metadata.Ref

  alias Mydia.Metadata.Structs.{
    EpisodeData,
    ImagesResponse,
    MediaMetadata,
    SearchResult,
    SeasonData,
    SeasonInfo
  }

  @movie_tmdb_id 550
  @series_tvdb_id 81_189
  @missing_id 999_999

  @movie_title "Stub Movie"
  @series_title "Stub Series"
  @season_fetch_block_key {__MODULE__, :season_fetch_block}
  @fetch_by_id_counts_table :mydia_metadata_stub_fetch_by_id_counts
  @raise_on_fetch_by_id_key {__MODULE__, :raise_on_fetch_by_id}
  @search_failure_key {__MODULE__, :search_failure}

  @doc "TMDB id of the catalog movie."
  def movie_tmdb_id, do: @movie_tmdb_id

  @doc "TVDB id of the catalog series."
  def series_tvdb_id, do: @series_tvdb_id

  @doc "Reserved id whose fetch always fails, for the approval-failure case."
  def missing_id, do: @missing_id

  @doc "Ref of the catalog series."
  def series_ref, do: {:tvdb, @series_tvdb_id}

  @doc "Ref of the catalog movie."
  def movie_ref, do: {:tmdb, @movie_tmdb_id}

  @doc "Title of the catalog movie."
  def movie_title, do: @movie_title

  @doc "Title of the catalog series."
  def series_title, do: @series_title

  @doc "Blocks the next season fetch until the calling test releases it."
  def block_next_season_fetch(owner) when is_pid(owner) do
    ref = make_ref()
    :persistent_term.put(@season_fetch_block_key, {owner, ref})
    ref
  end

  @doc "Clears a pending season-fetch block installed by a test."
  def clear_season_fetch_block(ref) do
    case :persistent_term.get(@season_fetch_block_key, nil) do
      {_owner, ^ref} -> :persistent_term.erase(@season_fetch_block_key)
      _other -> :ok
    end
  end

  @doc """
  Makes the next and all subsequent `search/3` calls fail until cleared.

  Opt-in: `search/3` only consults this key, so tests that never call it are
  unaffected.
  """
  def fail_search do
    :persistent_term.put(@search_failure_key, true)
    :ok
  end

  @doc "Clears a search failure installed by `fail_search/0`."
  def clear_search_failure do
    :persistent_term.erase(@search_failure_key)
    :ok
  end

  @doc """
  Starts (or clears) the `fetch_by_ref/3` call counter.

  Opt-in and purely additive: `fetch_by_ref/3` only counts a call when this
  table exists, so tests that never call this function see no behavior
  change. Used by `request_pages_poster_test.exs` to assert a permanently-
  unresolvable row is attempted exactly once per backfill pass, not retried
  in a loop.
  """
  def reset_fetch_by_id_count! do
    if :ets.whereis(@fetch_by_id_counts_table) == :undefined do
      :ets.new(@fetch_by_id_counts_table, [:named_table, :public, :set])
    else
      :ets.delete_all_objects(@fetch_by_id_counts_table)
    end

    :ok
  end

  @doc """
  Makes the next `fetch_by_ref/3` call for `media_ref` raise instead of
  returning the catalog entry.

  Opt-in and self-clearing: the next matching call consumes it and reverts to
  the normal catalog lookup, so a test that never triggers it (or fails
  before triggering it) leaves no state behind for later tests other than
  what `clear_raise_on_fetch_by_id/1` is meant to guard against -- call it
  from `on_exit/1` regardless of whether the raise fired. Used by
  `MediaRequestBackfillTest` to prove a raise inside one row of a concurrent
  backfill does not crash the caller or stop sibling rows.
  """
  def raise_on_fetch_by_id(media_ref) do
    token = make_ref()
    :persistent_term.put(@raise_on_fetch_by_id_key, {media_ref, token})
    token
  end

  @doc "Clears a pending `raise_on_fetch_by_id/1` installed by a test, if not already consumed."
  def clear_raise_on_fetch_by_id(token) do
    case :persistent_term.get(@raise_on_fetch_by_id_key, nil) do
      {_media_ref, ^token} -> :persistent_term.erase(@raise_on_fetch_by_id_key)
      _other -> :ok
    end
  end

  @doc "Number of `fetch_by_ref/3` calls observed for `media_ref` since the last reset."
  def fetch_by_id_count(media_ref) do
    case :ets.whereis(@fetch_by_id_counts_table) do
      :undefined ->
        0

      _tid ->
        case :ets.lookup(@fetch_by_id_counts_table, media_ref) do
          [{^media_ref, count}] -> count
          [] -> 0
        end
    end
  end

  @impl true
  def test_connection(_config), do: {:ok, %{status: "ok"}}

  @impl true
  def search(_config, _query, opts) do
    if :persistent_term.get(@search_failure_key, false) do
      {:error, Error.connection_failed("stubbed search failure")}
    else
      case Keyword.get(opts, :media_type) do
        :tv_show -> {:ok, [series_search_result()]}
        _ -> {:ok, [movie_search_result()]}
      end
    end
  end

  # The ref catalog is the source of truth: only `{:tvdb, @series_tvdb_id}`
  # and `{:tmdb, @movie_tmdb_id}` resolve. `{:tmdb, @series_tvdb_id}` -- the
  # exact pairing the deleted hotfix guard singled out -- is simply not a key
  # in this `case`, so it falls to the catch-all and answers not_found on its
  # own, the same way the relay answers 404 for a TVDB id sent to TMDB's
  # route.
  @impl true
  def fetch_by_ref(_config, ref, _opts) do
    count_fetch_by_id_call(ref)
    maybe_raise_on_fetch_by_id(ref)

    case ref do
      {:tvdb, @series_tvdb_id} -> {:ok, series_metadata()}
      {:tmdb, @movie_tmdb_id} -> {:ok, movie_metadata()}
      {_provider, id} -> {:error, Error.not_found("Media not found: #{id}")}
    end
  end

  # Shim. Deleted in the final task of this plan, along with every caller.
  # Forwards into `fetch_by_ref/3` via `Ref.legacy_from_opts/2`, mirroring
  # every real provider (see `Provider.Relay.fetch_by_id/3`) so a caller that
  # still goes through the id-based entry point is routed by exactly the same
  # ref the `fetch_by_ref/3` entry point would compute.
  @impl true
  def fetch_by_id(config, provider_id, opts) do
    fetch_by_ref(config, Ref.legacy_from_opts(provider_id, opts), opts)
  end

  @impl true
  def fetch_images_by_ref(_config, _ref, _opts) do
    {:ok, ImagesResponse.new(%{posters: [], backdrops: [], logos: []})}
  end

  # Shim. Deleted in the final task of this plan, along with every caller.
  @impl true
  def fetch_images(config, provider_id, opts) do
    fetch_images_by_ref(config, Ref.legacy_from_opts(provider_id, opts), opts)
  end

  @impl true
  def fetch_season_by_ref(_config, _ref, season_number, _opts) do
    maybe_block_season_fetch()

    {:ok,
     %SeasonData{
       season_number: season_number,
       name: "Season #{season_number}",
       overview: "Stub season.",
       episode_count: 2,
       episodes: [
         %EpisodeData{
           season_number: season_number,
           episode_number: 1,
           name: "Stub Episode One",
           overview: "First stub episode.",
           runtime: 42
         },
         %EpisodeData{
           season_number: season_number,
           episode_number: 2,
           name: "Stub Episode Two",
           overview: "Second stub episode.",
           runtime: 42
         }
       ]
     }}
  end

  # Shim. Deleted in the final task of this plan, along with every caller.
  @impl true
  def fetch_season(config, provider_id, season_number, opts) do
    fetch_season_by_ref(config, Ref.legacy_from_opts(provider_id, opts), season_number, opts)
  end

  @impl true
  def fetch_trending(_config, _opts), do: {:ok, []}

  ## Catalog

  defp count_fetch_by_id_call(media_ref) do
    case :ets.whereis(@fetch_by_id_counts_table) do
      :undefined ->
        :ok

      _tid ->
        :ets.update_counter(@fetch_by_id_counts_table, media_ref, {2, 1}, {media_ref, 0})
    end

    :ok
  end

  defp maybe_raise_on_fetch_by_id(media_ref) do
    case :persistent_term.get(@raise_on_fetch_by_id_key, nil) do
      {^media_ref, _token} ->
        :persistent_term.erase(@raise_on_fetch_by_id_key)
        raise "MetadataStubProvider: forced fetch_by_id failure for #{inspect(media_ref)}"

      _other ->
        :ok
    end
  end

  defp maybe_block_season_fetch do
    case :persistent_term.get(@season_fetch_block_key, nil) do
      {owner, ref} ->
        :persistent_term.erase(@season_fetch_block_key)
        send(owner, {:metadata_season_fetch_started, ref, self()})

        receive do
          {:release_metadata_season_fetch, ^ref} -> :ok
        after
          5_000 -> raise "timed out waiting to release the blocked metadata season fetch"
        end

      nil ->
        :ok
    end
  end

  defp movie_search_result do
    %SearchResult{
      provider_id: to_string(@movie_tmdb_id),
      provider: :metadata_relay,
      media_type: :movie,
      id: @movie_tmdb_id,
      title: @movie_title,
      original_title: @movie_title,
      # `year` is set explicitly rather than left for a caller to derive from
      # release_date: this struct is built as a literal, so nothing normalizes
      # it, and MetadataMatcher.calculate_movie_match_score/2 reads
      # `result.year` directly. A nil year costs the year bonus and lands the
      # score on 0.7999999999999999, just under FileIngest's 0.8 auto-link
      # threshold, which silently turns every "confident match" test into a
      # "cached candidate" one.
      year: 1999,
      release_date: "1999-03-30",
      overview: "A stub movie used by the guest request tests.",
      poster_path: "/stub-movie-poster.jpg",
      vote_average: 8.2
    }
  end

  # provider: :tvdb is load-bearing for `series_search_result/0`:
  # `MediaRequestHelpers.handle_request_media/3` branches on it to store the
  # id under tvdb_id rather than tmdb_id for a TV show request. See the
  # guest-request tv lifecycle tests in guest_request_flow_test.exs.
  defp series_search_result do
    %SearchResult{
      provider_id: to_string(@series_tvdb_id),
      provider: :tvdb,
      media_type: :tv_show,
      id: @series_tvdb_id,
      title: @series_title,
      name: @series_title,
      original_name: @series_title,
      first_air_date: "2008-01-20",
      overview: "A stub series used by the guest request tests.",
      poster_path: "/stub-series-poster.jpg",
      vote_average: 9.0
    }
  end

  defp movie_metadata do
    %MediaMetadata{
      provider_id: to_string(@movie_tmdb_id),
      provider: :metadata_relay,
      media_type: :movie,
      id: @movie_tmdb_id,
      title: @movie_title,
      original_title: @movie_title,
      year: 1999,
      release_date: "1999-03-30",
      overview: "A stub movie used by the guest request tests.",
      runtime: 136,
      genres: ["Action"],
      poster_path: "/stub-movie-poster.jpg",
      imdb_id: "tt0000550",
      original_language: "en",
      vote_average: 8.2
    }
  end

  # seasons must be non-empty for Media.create_media_item/2 to fetch episodes
  # (lib/mydia/media.ex:1354 reads `metadata.seasons || []`).
  defp series_metadata do
    %MediaMetadata{
      provider_id: to_string(@series_tvdb_id),
      provider: :tvdb,
      media_type: :tv_show,
      id: @series_tvdb_id,
      title: @series_title,
      original_title: @series_title,
      year: 2008,
      first_air_date: "2008-01-20",
      overview: "A stub series used by the guest request tests.",
      genres: ["Drama"],
      poster_path: "/stub-series-poster.jpg",
      imdb_id: "tt0000081",
      original_language: "en",
      number_of_seasons: 2,
      number_of_episodes: 4,
      vote_average: 9.0,
      seasons: [
        %SeasonInfo{
          season_number: 1,
          name: "Season 1",
          overview: "Stub season.",
          episode_count: 2
        },
        %SeasonInfo{
          season_number: 2,
          name: "Season 2",
          overview: "Stub season 2.",
          episode_count: 2
        }
      ]
    }
  end
end
