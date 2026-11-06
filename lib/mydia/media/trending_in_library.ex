defmodule Mydia.Media.TrendingInLibrary do
  @moduledoc """
  Ranks the titles a user owns and has not finished by TMDB trending, then
  TMDB popular.

  The walk goes through `trending` pages 1..3, then `popular` pages 1..5, each
  list stopping at its own `total_pages`. A title's rank is its position among
  the distinct TMDB ids fetched so far, so a title already seen on `trending`
  keeps that rank when `popular` lists it again. The walk halts as soon as
  `:limit` owned, unwatched titles are found.

  Owned means the title has at least one file and the scope may see it.
  Unwatched means a movie has no watched progress row, and a show still has at
  least one watchable episode left (see `Mydia.Playback.WatchStatus`).

  A fetch error before any page succeeded is returned as `{:error, reason}`.
  After that, an error ends the walk and the matches found so far are returned.
  """

  import Ecto.Query, only: [from: 2]

  alias Mydia.Accounts.Scope
  alias Mydia.Media
  alias Mydia.Media.MediaItem
  alias Mydia.Playback
  alias Mydia.Playback.WatchStatus

  @default_limit 20
  @plan [{:trending, 3}, {:popular, 5}]

  @type media_type :: :movie | :tv_show

  @doc """
  Returns `{:ok, [{media_item, rank}]}` in rank order, at most `:limit` long.

  ## Options

    * `:limit` - maximum matches, default #{@default_limit}
    * `:fetch` - `fun(list_type, media_type: t, page: p)` returning
      `{:ok, %{results: [%SearchResult{}], total_pages: n}}` or `{:error, reason}`.
      Defaults to `Mydia.Metadata.fetch_curated_list/2`.
  """
  @spec list(Scope.t(), term(), media_type(), keyword()) ::
          {:ok, [{MediaItem.t(), pos_integer()}]} | {:error, term()}
  def list(%Scope{} = scope, user_id, media_type, opts \\ [])
      when media_type in [:movie, :tv_show] do
    ctx = %{
      scope: scope,
      user_id: user_id,
      media_type: media_type,
      limit: Keyword.get(opts, :limit, @default_limit),
      fetch: Keyword.get(opts, :fetch, &Mydia.Metadata.fetch_curated_list/2),
      watched_movie_ids: nil
    }

    state = %{seen: MapSet.new(), matches: [], fetched_any?: false}

    steps = for {list, pages} <- @plan, page <- 1..pages, do: {list, page}

    case step_through(steps, nil, ctx, state) do
      {:error, reason} -> {:error, reason}
      {:ok, state} -> {:ok, state.matches |> Enum.reverse() |> Enum.take(ctx.limit)}
    end
  end

  # `last` is `{list, total_pages}` of the previous step, used to skip the
  # rest of a list once its last page was fetched.
  defp step_through([], _last, _ctx, state), do: {:ok, state}

  defp step_through([{list, page} | rest], last, ctx, state) do
    cond do
      limit_reached?(state, ctx) -> {:ok, state}
      past_last_page?(last, list, page) -> step_through(rest, last, ctx, state)
      true -> fetch_step(list, page, rest, ctx, state)
    end
  end

  defp limit_reached?(state, ctx), do: length(state.matches) >= ctx.limit

  defp past_last_page?({list, total}, list, page), do: page > total
  defp past_last_page?(_last, _list, _page), do: false

  defp fetch_step(list, page, rest, ctx, state) do
    list
    |> ctx.fetch.(media_type: ctx.media_type, page: page)
    |> absorb_page(list, page, rest, ctx, state)
  end

  defp absorb_page({:ok, %{results: results} = response}, list, page, rest, ctx, state) do
    total = Map.get(response, :total_pages) || page
    {ctx, state} = absorb(results, ctx, state)
    step_through(rest, {list, total}, ctx, %{state | fetched_any?: true})
  end

  defp absorb_page({:error, reason}, _list, _page, _rest, _ctx, state),
    do: end_walk(state, reason)

  defp absorb_page(_other, _list, _page, _rest, _ctx, state),
    do: end_walk(state, :unexpected_response)

  defp end_walk(%{fetched_any?: true} = state, _reason), do: {:ok, state}
  defp end_walk(_state, reason), do: {:error, reason}

  defp absorb(results, ctx, state) do
    new_ids =
      results
      |> Enum.flat_map(&parse_id(&1.provider_id))
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(state.seen, &1))

    ranks =
      new_ids
      |> Enum.with_index(MapSet.size(state.seen) + 1)
      |> Map.new()

    seen = Enum.reduce(new_ids, state.seen, &MapSet.put(&2, &1))

    {ctx, owned} = owned_unwatched(new_ids, ctx)

    matches =
      owned
      |> Enum.sort_by(&Map.fetch!(ranks, &1.tmdb_id))
      |> Enum.map(&{&1, Map.fetch!(ranks, &1.tmdb_id)})
      |> Enum.reduce(state.matches, &[&1 | &2])

    {ctx, %{state | seen: seen, matches: matches}}
  end

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> [int]
      _ -> []
    end
  end

  defp parse_id(id) when is_integer(id), do: [id]
  defp parse_id(_), do: []

  defp owned_unwatched([], ctx), do: {ctx, []}

  defp owned_unwatched(ids, ctx) do
    items =
      Media.list_media_items(ctx.scope,
        base_query: from(m in MediaItem, where: m.tmdb_id in ^ids),
        type: Atom.to_string(ctx.media_type),
        has_files: true
      )

    reject_watched(items, ctx)
  end

  defp reject_watched(items, %{media_type: :movie} = ctx) do
    ctx = load_watched_movies(ctx)
    {ctx, Enum.reject(items, &MapSet.member?(ctx.watched_movie_ids, &1.id))}
  end

  defp reject_watched(items, %{media_type: :tv_show} = ctx) do
    bundles = WatchStatus.load_shows(ctx.user_id, Enum.map(items, & &1.id))
    {ctx, Enum.reject(items, &WatchStatus.for_show(Map.get(bundles, &1.id)).watched)}
  end

  defp load_watched_movies(%{watched_movie_ids: nil} = ctx) do
    ids =
      ctx.user_id
      |> Playback.list_user_progress(watched: true)
      |> Enum.map(& &1.media_item_id)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    %{ctx | watched_movie_ids: ids}
  end

  defp load_watched_movies(ctx), do: ctx
end
