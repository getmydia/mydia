defmodule MydiaWeb.Live.Helpers.MediaRequestHelpers do
  @moduledoc """
  Shared LiveView helpers for the guest "Request" flow.

  Mirrors `MydiaWeb.Live.Helpers.MediaAddHelpers`: a status map, an enrichment
  pass over trending items, and a submit function. Used by DashboardLive and
  DiscoverLive so the request button behaves identically on both.
  """

  alias Mydia.Media.MediaRequest
  alias Mydia.Media.ProviderKey
  alias Mydia.MediaRequests
  alias Mydia.Metadata.Ref
  alias Mydia.Metadata.Structs.SearchResult
  alias MydiaWeb.Live.Helpers.MediaAddHelpers

  # Statuses that should keep the request button disabled. A rejected request
  # leaves the button enabled so a guest can ask again.
  @outstanding ~w(pending approved)

  # A relay round trip per row, so bounded. Four at a time keeps a large
  # pending queue from opening a connection storm while still finishing a
  # typical page in one round trip's time.
  @backfill_concurrency 4
  @backfill_timeout 30_000

  @doc """
  Maps a `Mydia.Media.ProviderKey` to request status for every outstanding
  request.

  The media type is part of the key because TMDB numbers movies and series
  independently: keyed on the bare id, a pending TV request for 550 rendered a
  movie with tmdb_id 550 as already "Requested". `enrich_with_request_status/2`
  looks up the same shape, and so does the library status map, so the Request
  and Add buttons on one card agree about which title they are describing.

  Deliberately not scoped to a requester. `MediaRequests.create_request/1`
  rejects duplicates globally via `pending_request_exists?/2`, so a per-user map
  would show a second guest an enabled button that errors on click.
  """
  @spec request_status_map() :: map()
  def request_status_map do
    @outstanding
    |> Enum.flat_map(&MediaRequests.list_requests(status: &1))
    |> Enum.reduce(%{}, fn request, acc ->
      case status_map_key(request) do
        nil -> acc
        key -> Map.put_new(acc, key, request.status)
      end
    end)
  end

  @doc """
  Adds a `:request_status` field to each item, or nil when it has no request.
  """
  def enrich_with_request_status(items, request_status_map) do
    Enum.map(items, fn item ->
      status =
        case ProviderKey.from_card(item) do
          nil -> nil
          key -> Map.get(request_status_map, key)
        end

      Map.put(item, :request_status, status)
    end)
  end

  # A request stores exactly one of tmdb_id/tvdb_id (see handle_request_media/3),
  # and `external_ref/1` reports which, so the provider half of the key is never
  # a guess here.
  defp status_map_key(request) do
    case MediaRequest.external_ref(request) do
      {provider, id} -> ProviderKey.new(MediaRequest.media_type_atom(request), provider, id)
      nil -> nil
    end
  end

  @doc """
  Submits a request for a trending card item.

  Returns `{:ok, request, updated_status_map}` or `{:error, reason}` where
  reason is `:duplicate_media`, `:duplicate_request`, or a changeset.

  The card carries no `imdb_id` or `original_title`; approval re-fetches from
  the provider and resolves both, so nothing is lost by not fetching here. That
  keeps the button instant.
  """
  @spec handle_request_media(map(), :movie | :tv_show, String.t()) ::
          {:ok, Mydia.Media.MediaRequest.t(), map()} | {:error, term()}
  def handle_request_media(item, media_type, requester_id) do
    base = %{
      media_type: if(media_type == :movie, do: "movie", else: "tv_show"),
      title: item.title,
      year: Map.get(item, :year),
      poster_path: Map.get(item, :poster_path),
      requester_id: requester_id
    }

    # A TV show sourced from TVDB stores tvdb_id instead of tmdb_id; every
    # other case (movies always, TV shows sourced from TMDB) is unchanged.
    # Mirrors the deleted RequestMediaLive.Index.build_request_attrs/3.
    #
    # `media_type` gates this, not the ref's tag alone: there is no TVDB movie
    # catalog, so a movie card mistagged `provider: :tvdb` must be rejected
    # rather than stored under tmdb_id, which would name an unrelated TMDB
    # title (or none at all) with the TVDB catalog's numeric id. Mirrors the
    # `{:movie, {:tvdb, _}} -> {:error, {:metadata, :tvdb_ref_for_movie}}`
    # guard in `Mydia.Media.Add.resolve_attrs/4`.
    case {media_type, Ref.from_search_result(item)} do
      {:movie, {:tvdb, _id}} ->
        {:error, {:metadata, :tvdb_ref_for_movie}}

      {:tv_show, {:tvdb, id}} ->
        submit_request(Map.put(base, :tvdb_id, id))

      {_media_type, ref} ->
        submit_request(Map.put(base, :tmdb_id, Ref.id(ref)))
    end
  end

  defp submit_request(attrs) do
    case MediaRequests.create_request(attrs) do
      {:ok, request} ->
        {:ok, request, %{status_map_key(request) => request.status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Resolves provider metadata for a request.

  Lives here rather than in `Mydia.MediaRequests` because it delegates to
  `MediaAddHelpers.fetch_detail_metadata/3`, which is already a web helper.
  Putting it in the context would point a context module at `MydiaWeb`.

  `MediaRequest.external_ref/1` already carries the provider that owns the
  stored id, so it passes straight through with no conversion: a TMDB-sourced
  request reuses the Discovery helper's TMDB-to-TVDB resolution for TV, and a
  TVDB-sourced request (stored when a TV request is made on a
  TVDB-configured instance, which has no tmdb_id) fetches TVDB directly.
  """
  @spec fetch_request_metadata(MediaRequest.t()) ::
          {:ok, Mydia.Metadata.Structs.MediaMetadata.t()} | {:error, term()}
  def fetch_request_metadata(%MediaRequest{} = request) do
    case MediaRequest.external_ref(request) do
      nil ->
        {:error, :no_provider_id}

      ref ->
        MediaAddHelpers.fetch_detail_metadata(ref, MediaRequest.media_type_atom(request))
    end
  end

  @doc """
  Builds the `SearchResult` that `TrendingDetailModal` reads for its header.

  Returns nil for a request with no external ref, which is the same set of rows
  that render a non-clickable title.
  """
  @spec to_search_result(MediaRequest.t()) :: SearchResult.t() | nil
  def to_search_result(%MediaRequest{} = request) do
    case MediaRequest.external_ref(request) do
      nil ->
        nil

      {provider, id} ->
        %SearchResult{
          provider_id: to_string(id),
          provider: provider,
          media_type: MediaRequest.media_type_atom(request),
          id: id,
          title: request.title,
          year: request.year,
          poster_path: request.poster_path
        }
    end
  end

  @doc """
  Whether this request should be resolved for a poster.
  """
  @spec needs_poster?(MediaRequest.t()) :: boolean()
  def needs_poster?(%MediaRequest{poster_path: nil} = request),
    do: MediaRequest.detailable?(request)

  def needs_poster?(%MediaRequest{}), do: false

  @doc """
  Resolves and stores posters for requests that have none.

  Callers run this inside a `start_async/3` task, never inline: a relay round
  trip per row inside `mount/3`, `handle_event`, or `handle_info` would block
  the LiveView process while its page is already on screen. Deferring only to
  `handle_info` (as this used to) merely lets the first render paint -- the
  process is still blocked for every event afterward (Close, Approve, Reject)
  while the batch runs, so `start_async/3` is what actually keeps it
  responsive.

  A failed or timed-out fetch leaves `poster_path` nil, so the card falls back
  to the placeholder and the next visit to the page retries. There is
  deliberately no retry inside a single pass.
  """
  @spec backfill_poster_paths([MediaRequest.t()]) :: :ok
  def backfill_poster_paths(requests) when is_list(requests) do
    requests
    |> Enum.filter(&needs_poster?/1)
    |> Task.async_stream(&backfill_one/1,
      max_concurrency: @backfill_concurrency,
      timeout: @backfill_timeout,
      on_timeout: :kill_task
    )
    |> Stream.run()

    :ok
  end

  defp backfill_one(request) do
    # `Task.async_stream/3` links each task to the caller, which is the
    # `start_async/3` task that AdminRequestsLive/MyRequestsLive spawn from
    # `maybe_backfill_posters/2` (see their `handle_async(:backfill_posters,
    # ...)`), not the LiveView process itself. `fetch_request_metadata/1`
    # parses an upstream JSON payload this code does not control (via
    # `MediaAddHelpers.fetch_detail_metadata/3` and `Metadata.fetch_by_ref/3`
    # into the relay provider), so a malformed response raising here is
    # realistic. An uncaught raise here would still be isolated from the
    # LiveView process -- `start_async/3` reports it to `handle_async/3` as
    # `{:exit, reason}` rather than crashing the page -- but it would also
    # abort every other row still in flight in this batch. Catch it here
    # instead, matching
    # `Mydia.Metadata.Provider.Relay.fetch_all_season_episodes/3`, which
    # rescues at the same kind of single-relay-call-per-task boundary.
    try do
      with {:ok, metadata} <- fetch_request_metadata(request),
           path when is_binary(path) <- metadata.poster_path,
           {:ok, _updated} <- MediaRequests.update_poster_path(request, path) do
        :ok
      else
        _ -> :ok
      end
    rescue
      _exception -> :ok
    end
  end
end
