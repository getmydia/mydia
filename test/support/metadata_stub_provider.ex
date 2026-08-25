defmodule Mydia.MetadataStubProvider do
  @moduledoc """
  Deterministic in-memory metadata provider for tests.

  Registered under `:metadata_relay` by `Mydia.MetadataStub.setup_metadata_stub/1`,
  which is the only seam that reaches both guest search and admin approval.
  `AdminRequestsLive.Index` calls `MediaRequests.approve_request/2` without a
  config, so injecting a Bypass config cannot cover the approval path.

  The catalog is deliberately tiny and self-consistent: every id `search/3`
  returns is resolvable by `fetch_by_id/3`, because approval re-fetches by that
  id. A catalog that violates this reproduces the original defect, where the
  test seeded an id the relay had never heard of and the approval silently
  failed.
  """

  @behaviour Mydia.Metadata.Provider

  alias Mydia.Metadata.Provider.Error

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

  @doc "TMDB id of the catalog movie."
  def movie_tmdb_id, do: @movie_tmdb_id

  @doc "TVDB id of the catalog series."
  def series_tvdb_id, do: @series_tvdb_id

  @doc "Reserved id whose fetch always fails, for the approval-failure case."
  def missing_id, do: @missing_id

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
  Starts (or clears) the `fetch_by_id/3` call counter.

  Opt-in and purely additive: `fetch_by_id/3` only counts a call when this
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
  Makes the next `fetch_by_id/3` call for `provider_id` raise instead of
  returning the catalog entry.

  Opt-in and self-clearing: the next matching call consumes it and reverts to
  the normal catalog lookup, so a test that never triggers it (or fails
  before triggering it) leaves no state behind for later tests other than
  what `clear_raise_on_fetch_by_id/1` is meant to guard against -- call it
  from `on_exit/1` regardless of whether the raise fired. Used by
  `MediaRequestBackfillTest` to prove a raise inside one row of a concurrent
  backfill does not crash the caller or stop sibling rows.
  """
  def raise_on_fetch_by_id(provider_id) do
    ref = make_ref()
    :persistent_term.put(@raise_on_fetch_by_id_key, {to_string(provider_id), ref})
    ref
  end

  @doc "Clears a pending `raise_on_fetch_by_id/1` installed by a test, if not already consumed."
  def clear_raise_on_fetch_by_id(ref) do
    case :persistent_term.get(@raise_on_fetch_by_id_key, nil) do
      {_provider_id, ^ref} -> :persistent_term.erase(@raise_on_fetch_by_id_key)
      _other -> :ok
    end
  end

  @doc "Number of `fetch_by_id/3` calls observed for `provider_id` since the last reset."
  def fetch_by_id_count(provider_id) do
    case :ets.whereis(@fetch_by_id_counts_table) do
      :undefined ->
        0

      _tid ->
        case :ets.lookup(@fetch_by_id_counts_table, provider_id) do
          [{^provider_id, count}] -> count
          [] -> 0
        end
    end
  end

  @impl true
  def test_connection(_config), do: {:ok, %{status: "ok"}}

  @impl true
  def search(_config, _query, opts) do
    case Keyword.get(opts, :media_type) do
      :tv_show -> {:ok, [series_search_result()]}
      _ -> {:ok, [movie_search_result()]}
    end
  end

  @impl true
  def fetch_by_id(_config, provider_id, opts) do
    count_fetch_by_id_call(provider_id)
    maybe_raise_on_fetch_by_id(provider_id)

    cond do
      provider_id == to_string(@missing_id) ->
        {:error, Error.not_found("Media not found: #{@missing_id}")}

      Keyword.get(opts, :provider) == :tvdb or Keyword.get(opts, :media_type) == :tv_show ->
        {:ok, series_metadata()}

      true ->
        {:ok, movie_metadata()}
    end
  end

  @impl true
  def fetch_images(_config, _provider_id, _opts) do
    {:ok, ImagesResponse.new(%{posters: [], backdrops: [], logos: []})}
  end

  @impl true
  def fetch_season(_config, _provider_id, season_number, _opts) do
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

  @impl true
  def fetch_trending(_config, _opts), do: {:ok, []}

  ## Catalog

  defp count_fetch_by_id_call(provider_id) do
    case :ets.whereis(@fetch_by_id_counts_table) do
      :undefined ->
        :ok

      _tid ->
        :ets.update_counter(@fetch_by_id_counts_table, provider_id, {2, 1}, {provider_id, 0})
    end

    :ok
  end

  defp maybe_raise_on_fetch_by_id(provider_id) do
    case :persistent_term.get(@raise_on_fetch_by_id_key, nil) do
      {^provider_id, _ref} ->
        :persistent_term.erase(@raise_on_fetch_by_id_key)
        raise "MetadataStubProvider: forced fetch_by_id failure for #{provider_id}"

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

  # provider: :tvdb is load-bearing. RequestMediaLive.Index.build_request_attrs/3
  # only stores tvdb_id when the result carries it, and MediaRequests routes
  # approval by which id is present.
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
