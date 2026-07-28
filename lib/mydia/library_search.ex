defmodule Mydia.LibrarySearch do
  @moduledoc """
  Library search: finding media the user already has.

  Not to be confused with `Mydia.Search`, which is *indexer* search backoff —
  querying torrent and usenet indexers for downloadable releases. The two share
  no code and must not be conflated.

  Search spans `Mydia.Media` and `Mydia.Collections` and belongs in neither, so
  it lives in its own context.

      {:ok, results} = Mydia.LibrarySearch.search(user, "alien", limit: 20)

  ## Options

    * `:types` - sections to include, any of `:movie`, `:tv_show`, `:episode`,
      `:collection`. Defaults to all four.
    * `:limit` - rows per section. Defaults to 20.

  ## Query shape

  Each requested section runs one row query and one `COUNT` query, so a full
  search is eight queries plus one `item_count` per returned collection.
  Movies and TV shows share the `media_items` table but still get their own
  query pair: splitting a single result set in Elixir would break the
  per-section limit, since one `LIMIT 20` over both types cannot guarantee
  twenty of each.

  The counts are deliberate. Section headers show a total and each section offers
  "Show all", both of which need a real count rather than the length of an
  already-truncated page.

  ## Matching

  Each normalized token contributes one `LIKE %token%` predicate and all of them
  are `AND`-ed, which makes matching word-order independent: "night journey"
  matches "Long Day's Journey Into Night". Media items match on `title` or
  `original_title`; episodes on `episodes.title`; collections on
  `collections.name`.

  ## Indexes

  No index work is required and none is planned. `media_items.title` is already
  indexed, `episodes.title` and `collections.name` are not, and a leading-wildcard
  `LIKE` cannot use a B-tree index either way. At this scale — thousands of media
  items, tens of thousands of episodes — a scan completes in well under a
  millisecond. Recorded so the omission reads as deliberate.

  ## Authorization

  `user` is a required positional argument, never an option, because this is the
  one place the feature can leak data and a positional argument is compiler
  enforced. Collections are filtered with the same predicate used everywhere else
  in `Mydia.Collections`. Movies, shows, and episodes are not user-scoped in the
  current data model and need no additional filtering.
  """

  import Ecto.Query, warn: false
  require Mydia.LibrarySearch.Rank

  alias Mydia.Accounts.User
  alias Mydia.Collections
  alias Mydia.Collections.Collection
  alias Mydia.LibrarySearch.{Rank, Result, Results, Section, Tokenizer}
  alias Mydia.Media.{Episode, MediaItem}
  alias Mydia.Metadata.Access, as: MetadataAccess
  alias Mydia.Repo

  @default_limit 20
  @section_order [:movie, :tv_show, :episode, :collection]

  @doc """
  Searches the user's library and returns grouped sections.

  Returns `{:ok, %Results{}}`. A query that normalizes to zero tokens returns
  empty sections without touching the database. Sections with no matches are
  omitted from the response entirely.
  """
  @spec search(User.t(), String.t(), keyword()) :: {:ok, Results.t()}
  def search(%User{} = user, query, opts \\ []) do
    types = Keyword.get(opts, :types, @section_order)
    limit = Keyword.get(opts, :limit, @default_limit)

    case Tokenizer.normalize(query) do
      :empty ->
        {:ok, %Results{sections: [], total_count: 0}}

      {:ok, normalized} ->
        sections =
          @section_order
          |> Enum.filter(&(&1 in types))
          |> Enum.map(&build_section(&1, user, normalized, limit))
          |> Enum.reject(&(&1.total_count == 0))

        {:ok,
         %Results{
           sections: sections,
           total_count: sections |> Enum.map(& &1.total_count) |> Enum.sum()
         }}
    end
  end

  ## Sections

  defp build_section(type, _user, normalized, limit) when type in [:movie, :tv_show] do
    base = media_item_base(Atom.to_string(type), normalized)

    results =
      base
      |> media_item_rows(normalized, limit)
      |> Repo.all()
      |> Enum.map(&build_media_item_result(&1, type))

    %Section{type: type, results: results, total_count: Repo.aggregate(base, :count)}
  end

  defp build_section(:episode, _user, normalized, limit) do
    base = episode_base(normalized)

    results =
      base
      |> episode_rows(normalized, limit)
      |> Repo.all()
      |> Enum.map(&build_episode_result/1)

    %Section{type: :episode, results: results, total_count: Repo.aggregate(base, :count)}
  end

  defp build_section(:collection, %User{} = user, normalized, limit) do
    base = collection_base(user, normalized)

    results =
      base
      |> collection_rows(normalized, limit)
      |> Repo.all()
      |> Enum.map(&build_collection_result/1)

    %Section{type: :collection, results: results, total_count: Repo.aggregate(base, :count)}
  end

  ## media_items

  defp media_item_base(db_type, normalized) do
    Enum.reduce(normalized.tokens, from(m in MediaItem, where: m.type == ^db_type), fn token,
                                                                                       query ->
      pattern = Tokenizer.contains_pattern(token)

      where(
        query,
        [m],
        fragment("lower(?) LIKE ? ESCAPE '\\'", m.title, ^pattern) or
          fragment("lower(?) LIKE ? ESCAPE '\\'", m.original_title, ^pattern)
      )
    end)
  end

  defp media_item_rows(base, normalized, limit) do
    prefix = Tokenizer.prefix_pattern(normalized.query)
    word = Tokenizer.word_pattern(normalized.query)

    from(m in base,
      select: %{
        item: m,
        rank: selected_as(Rank.rank(m.title, ^normalized.query, ^prefix, ^word), :rank)
      },
      order_by: [desc: selected_as(:rank), asc: m.title],
      limit: ^limit
    )
  end

  defp build_media_item_result(%{item: item, rank: rank}, type) do
    %Result{
      id: item.id,
      type: type,
      title: item.title,
      year: item.year,
      score: rank / 1,
      poster_path: MetadataAccess.get_field(item, :poster_path),
      backdrop_path: MetadataAccess.get_field(item, :backdrop_path)
    }
  end

  ## episodes

  defp episode_base(normalized) do
    Enum.reduce(
      normalized.tokens,
      from(e in Episode, join: m in assoc(e, :media_item), as: :show),
      fn token, query ->
        pattern = Tokenizer.contains_pattern(token)

        where(query, [e], fragment("lower(?) LIKE ? ESCAPE '\\'", e.title, ^pattern))
      end
    )
  end

  defp episode_rows(base, normalized, limit) do
    prefix = Tokenizer.prefix_pattern(normalized.query)
    word = Tokenizer.word_pattern(normalized.query)

    from([e, show: m] in base,
      select: %{
        episode: e,
        show: m,
        rank: selected_as(Rank.rank(e.title, ^normalized.query, ^prefix, ^word), :rank)
      },
      order_by: [desc: selected_as(:rank), asc: e.title],
      limit: ^limit
    )
  end

  defp build_episode_result(%{episode: episode, show: show, rank: rank}) do
    %Result{
      id: episode.id,
      type: :episode,
      title: episode.title,
      score: rank / 1,
      subtitle: show.title,
      season_number: episode.season_number,
      episode_number: episode.episode_number,
      parent_id: show.id,
      still_path: MetadataAccess.get_field(episode, :still_path),
      poster_path: MetadataAccess.get_field(show, :poster_path),
      backdrop_path: MetadataAccess.get_field(show, :backdrop_path)
    }
  end

  ## collections

  # Same visibility predicate used everywhere else in Mydia.Collections: the
  # user's own collections plus anyone's shared ones.
  defp collection_base(%User{} = user, normalized) do
    base = from(c in Collection, where: c.user_id == ^user.id or c.visibility == "shared")

    Enum.reduce(normalized.tokens, base, fn token, query ->
      pattern = Tokenizer.contains_pattern(token)

      where(query, [c], fragment("lower(?) LIKE ? ESCAPE '\\'", c.name, ^pattern))
    end)
  end

  defp collection_rows(base, normalized, limit) do
    prefix = Tokenizer.prefix_pattern(normalized.query)
    word = Tokenizer.word_pattern(normalized.query)

    from(c in base,
      select: %{
        collection: c,
        rank: selected_as(Rank.rank(c.name, ^normalized.query, ^prefix, ^word), :rank)
      },
      order_by: [desc: selected_as(:rank), asc: c.name],
      limit: ^limit
    )
  end

  defp build_collection_result(%{collection: collection, rank: rank}) do
    %Result{
      id: collection.id,
      type: :collection,
      title: collection.name,
      score: rank / 1,
      subtitle: item_count_label(Collections.item_count(collection)),
      poster_path: collection.poster_path
    }
  end

  defp item_count_label(1), do: "1 item"
  defp item_count_label(count), do: "#{count} items"
end
