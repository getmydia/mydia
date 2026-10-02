defmodule Mydia.Plugins.PageReads do
  @moduledoc """
  Reads for plugin pages: search over the library and the catalog, and the
  acting user's own requests, downloads and collections. Valid inside an
  `on-http` or `fill-shelf` invocation, where the host knows whose data to read. Every read runs as
  that user and never returns another user's rows.

  ## Download scoping

  Downloads carry no user attribution: a `downloads` row links only to a media
  item and episode, never to whoever asked for it. The `download` namespace is
  therefore scoped through the one real link that exists, the acting user's
  own media requests. A download is returned when its media item (or its
  episode's media item) is the target of a request the user made. Downloads
  the user did not request, including everything an admin queued by hand, are
  not returned, even to admins. Any request by the user counts, whatever its
  status (pending, approved or rejected).
  """

  import Ecto.Query, only: [from: 2]

  import Mydia.Plugins.PageContext, only: [acting_user: 1, opt: 2, to_option: 1, iso: 1]

  alias Mydia.Accounts.Scope
  alias Mydia.Collections
  alias Mydia.Downloads
  alias Mydia.LibrarySearch
  alias Mydia.MediaRequests
  alias Mydia.Metadata
  alias Mydia.Playback
  alias Mydia.Plugins.Error
  alias Mydia.Plugins.HostFunctions
  alias Mydia.Repo

  @search_cap 25
  @history_cap 50
  @history_default 20
  @default_limit 10

  @doc """
  Searches the user's visible library (`kind: :library`) or the metadata
  catalog (`kind: :catalog`). Requires `data:search`.
  """
  def search(plugin, ctx, req) do
    with :ok <- require_flag(plugin, "data:search"),
         {:ok, user} <- acting_user(ctx) do
      limit = req |> opt(:limit) |> clamp_limit()
      types = req |> opt(:"media-type") |> media_types()
      query = Map.get(req, :query, "")

      case Map.get(req, :kind) do
        :library -> library_hits(user, query, types, limit)
        :catalog -> catalog_hits(query, types, limit)
        _ -> {:error, Error.new(:invalid_request, "unknown search kind")}
      end
    end
  end

  @doc """
  Lists the acting user's rows for `media_request`, `download` or `collection`.
  Requires `data:read` for the namespace.
  """
  def list(namespace, plugin, ctx) do
    with :ok <- require_namespace(plugin, namespace),
         {:ok, user} <- acting_user(ctx) do
      {:ok, %{items: rows(namespace, user), "next-cursor": :none}}
    end
  end

  @doc """
  The acting user's watch history for the `watch_history` namespace: progress
  rows newest first by `last_watched_at`, as `playback-progress` records.
  Requires `data:read` for `watch_history`.

  `updated-since`, for this namespace, bounds `last_watched_at` rather than the
  row's update time. `limit` is clamped to 1..#{@history_cap}. There is no
  cursor. An episode row's `media-item-id` is its show's id, so the guest can
  resolve a title with `data-read`. `with_origin?` follows the guest's
  contract: only a 1.5 record carries `origin`.
  """
  def watch_history(plugin, ctx, req, with_origin?) do
    with :ok <- require_namespace(plugin, "watch_history"),
         {:ok, user} <- acting_user(ctx),
         {:ok, since} <- history_since(opt(req, :"updated-since")) do
      limit = history_limit(opt(req, :limit))

      items =
        for p <- Playback.list_user_history(user.id, limit: limit, since: since) do
          {:"playback-progress", history_record(p, with_origin?)}
        end

      {:ok, %{items: items, "next-cursor": :none}}
    end
  end

  defp history_record(p, with_origin?) do
    record = HostFunctions.to_playback_progress(p, with_origin?)

    case p.episode do
      %{media_item_id: show_id} when is_binary(show_id) ->
        Map.put(record, :"media-item-id", {:some, show_id})

      _ ->
        record
    end
  end

  defp history_since(nil), do: {:ok, nil}

  defp history_since(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, ts, _} -> {:ok, ts}
      _ -> {:error, Error.new(:invalid_request, "updated-since must be an RFC3339 timestamp")}
    end
  end

  defp history_limit(n) when is_integer(n) and n > 0, do: min(n, @history_cap)
  defp history_limit(_), do: @history_default

  defp rows("media_request", user) do
    for r <- MediaRequests.list_requests(requester_id: user.id) do
      {:"media-request",
       %{
         id: r.id,
         title: r.title || "",
         "media-type": r.media_type || "",
         status: r.status || "",
         year: to_option(r.year),
         "tmdb-id": to_option(r.tmdb_id),
         "updated-at": iso(r.updated_at)
       }}
    end
  end

  defp rows("download", user) do
    case requested_media_ids(user) do
      [] ->
        []

      ids ->
        ids = MapSet.new(ids)

        for d <- Downloads.list_active_downloads(), requested_download?(d, ids) do
          {:download,
           %{
             id: to_string(d.id),
             title: d.title || "",
             status: to_string(d.status),
             progress: to_option(d.progress && d.progress * 1.0),
             "eta-seconds": to_option(if(is_integer(d.eta), do: d.eta))
           }}
        end
    end
  end

  defp rows("collection", user) do
    scope = Scope.for_user(user)

    for c <- Collections.list_collections(user, include_shared: false) do
      {:collection,
       %{
         id: c.id,
         name: c.name,
         kind: c.type,
         "item-count": Collections.item_count(scope, c),
         "is-system": c.is_system == true,
         "updated-at": iso(c.updated_at)
       }}
    end
  end

  defp requested_media_ids(user) do
    Repo.all(
      from(r in Mydia.Media.MediaRequest,
        where: r.requester_id == ^user.id and not is_nil(r.media_item_id),
        select: r.media_item_id,
        distinct: true
      )
    )
  end

  defp requested_download?(download, ids) do
    episode_item_id = download.episode && download.episode.media_item_id

    MapSet.member?(ids, download.media_item_id) or
      (episode_item_id != nil and MapSet.member?(ids, episode_item_id))
  end

  defp library_hits(user, query, types, limit) do
    {:ok, results} = LibrarySearch.search(user, query, types: types, limit: limit)

    hits =
      for section <- results.sections, r <- section.results do
        %{
          kind: :library,
          "item-type": to_string(r.type),
          title: r.title || "",
          year: to_option(r.year),
          "media-item-id": {:some, r.id},
          "tmdb-id": :none,
          "tvdb-id": :none,
          "poster-path": to_option(r.poster_path),
          overview: :none
        }
      end

    {:ok, Enum.take(hits, limit)}
  end

  defp catalog_hits(query, types, limit) do
    if String.trim(query) == "" do
      {:ok, []}
    else
      config = Metadata.default_relay_config()

      outcomes =
        Enum.map(types, fn type ->
          with {:ok, results} <- Metadata.search_cached(config, query, media_type: type) do
            {:ok, Enum.map(results, &catalog_hit(&1, type))}
          end
        end)

      case Enum.split_with(outcomes, &match?({:ok, _}, &1)) do
        {[], [_ | _]} ->
          {:error, Error.new(:network_error, "catalog search is unavailable")}

        {ok, _failed} ->
          {:ok, ok |> Enum.flat_map(fn {:ok, hits} -> hits end) |> Enum.take(limit)}
      end
    end
  end

  defp catalog_hit(r, type) do
    id = to_option(int(r.provider_id))
    {tmdb, tvdb} = if r.provider == :tvdb, do: {:none, id}, else: {id, :none}

    %{
      kind: :catalog,
      "item-type": Atom.to_string(type),
      title: r.title || r.name || "",
      year: to_option(r.year),
      "media-item-id": :none,
      "tmdb-id": tmdb,
      "tvdb-id": tvdb,
      "poster-path": to_option(r.poster_path),
      overview: to_option(r.overview)
    }
  end

  defp clamp_limit(n) when is_integer(n) and n > 0, do: min(n, @search_cap)
  defp clamp_limit(_), do: @default_limit

  defp media_types("movie"), do: [:movie]
  defp media_types("tv_show"), do: [:tv_show]
  defp media_types(_), do: [:movie, :tv_show]

  defp require_flag(plugin, class) do
    if Map.has_key?(plugin.granted_capabilities, class),
      do: :ok,
      else: {:error, Error.new(:capability_denied, "#{class} not granted")}
  end

  defp require_namespace(plugin, ns) do
    if ns in List.wrap(Map.get(plugin.granted_capabilities, "data:read")),
      do: :ok,
      else: {:error, Error.new(:capability_denied, "data:read #{ns} not granted")}
  end

  defp int(n) when is_integer(n), do: n

  defp int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp int(_), do: nil
end
