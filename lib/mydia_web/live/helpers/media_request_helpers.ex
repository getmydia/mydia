defmodule MydiaWeb.Live.Helpers.MediaRequestHelpers do
  @moduledoc """
  Shared LiveView helpers for the guest "Request" flow.

  Mirrors `MydiaWeb.Live.Helpers.MediaAddHelpers`: a status map, an enrichment
  pass over trending items, and a submit function. Used by DashboardLive and
  DiscoverLive so the request button behaves identically on both.
  """

  alias Mydia.Media.Add
  alias Mydia.Media.MediaRequest
  alias Mydia.MediaRequests
  alias Mydia.Metadata
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
  Maps `tmdb_id` to request status for every outstanding request.

  Deliberately not scoped to a requester. `MediaRequests.create_request/1`
  rejects duplicates globally via `pending_request_exists?/1`, so a per-user map
  would show a second guest an enabled button that errors on click.
  """
  @spec request_status_map() :: %{integer() => String.t()}
  def request_status_map do
    @outstanding
    |> Enum.flat_map(&MediaRequests.list_requests(status: &1))
    |> Enum.reduce(%{}, fn request, acc ->
      case request.tmdb_id do
        nil -> acc
        tmdb_id -> Map.put_new(acc, tmdb_id, request.status)
      end
    end)
  end

  @doc """
  Adds a `:request_status` field to each item, or nil when it has no request.
  """
  def enrich_with_request_status(items, request_status_map) do
    Enum.map(items, fn item ->
      status = Map.get(request_status_map, Add.parse_provider_id(item.provider_id))
      Map.put(item, :request_status, status)
    end)
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
    tmdb_id = Add.parse_provider_id(item.provider_id)

    attrs = %{
      media_type: if(media_type == :movie, do: "movie", else: "tv_show"),
      title: item.title,
      year: Map.get(item, :year),
      tmdb_id: tmdb_id,
      poster_path: Map.get(item, :poster_path),
      requester_id: requester_id
    }

    case MediaRequests.create_request(attrs) do
      {:ok, request} -> {:ok, request, %{tmdb_id => request.status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Resolves provider metadata for a request.

  Lives here rather than in `Mydia.MediaRequests` because the TMDB branch
  delegates to `MediaAddHelpers.fetch_detail_metadata/2`, which is already a
  web helper. Putting it in the context would point a context module at
  `MydiaWeb`.

  The TMDB branch reuses the Discovery helper so both surfaces show the same
  metadata for the same title, including its TMDB-to-TVDB resolution for TV.
  The TVDB branch mirrors `Mydia.Media.Add.fetch_tvdb_series/2` and exists
  because a TV request made on a TVDB-configured instance stores no tmdb_id.
  """
  @spec fetch_request_metadata(MediaRequest.t()) ::
          {:ok, Mydia.Metadata.Structs.MediaMetadata.t()} | {:error, term()}
  def fetch_request_metadata(%MediaRequest{} = request) do
    case MediaRequest.external_ref(request) do
      {:tmdb, tmdb_id} ->
        MediaAddHelpers.fetch_detail_metadata(
          to_string(tmdb_id),
          MediaRequest.media_type_atom(request)
        )

      {:tvdb, tvdb_id} ->
        Metadata.fetch_by_id(
          Metadata.default_relay_config(),
          to_string(tvdb_id),
          media_type: :tv_show,
          provider: :tvdb
        )

      nil ->
        {:error, :no_provider_id}
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

  Callers run this from `handle_info`, never inline: a relay round trip inside
  `mount/3` or a `handle_event` would freeze the LiveView process while its
  page is already on screen.

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
    with {:ok, metadata} <- fetch_request_metadata(request),
         path when is_binary(path) <- metadata.poster_path,
         {:ok, _updated} <- MediaRequests.update_poster_path(request, path) do
      :ok
    else
      _ -> :ok
    end
  end
end
