defmodule Mydia.Library.CandidateSuggestions do
  @moduledoc """
  Ranks import candidates as possible files for a movie or episode that has
  none, for the "Find file" dialog.

  The pool is every candidate in a compatible, enabled library path with no
  queued operation, pending or dismissed alike: a file parked by "Remove from
  Library" is dismissed and is exactly what a re-added title wants back.
  Ranking is local and cheap (filename parse plus title similarity), never a
  metadata-relay call.
  """

  import Ecto.Query

  alias Mydia.ImportCandidates
  alias Mydia.Library.{CandidateSuggestion, ImportCandidate, MediaFile, ReleaseParser, Text}
  alias Mydia.Media.{Episode, MediaItem}
  alias Mydia.Repo

  @pool_cap 500
  @default_limit 25
  @title_floor 0.8
  @max_tokens 5
  @min_token_length 3

  @doc """
  Ranked suggestions for a movie `MediaItem` or an `Episode` (with its
  `:media_item` preloaded). Options: `:query` (path substring search) and
  `:limit`.
  """
  @spec suggest_for(MediaItem.t() | Episode.t(), keyword()) :: [CandidateSuggestion.t()]
  def suggest_for(target, opts \\ []) do
    query = normalize_query(Keyword.get(opts, :query))
    limit = Keyword.get(opts, :limit, @default_limit)
    item = item_of(target)
    identity = ImportCandidates.provider_identity(item)

    target
    |> pool_query(identity, query)
    |> Repo.all()
    |> Enum.map(&score(&1, target, item, identity))
    |> Enum.filter(&(plausible?(&1) or searching?(query)))
    |> Enum.sort_by(&{-&1.score, &1.candidate.id})
    |> Enum.take(limit)
  end

  @doc "Library path types that can hold a file for a movie `MediaItem` or an `Episode`."
  @spec compatible_library_types(Episode.t() | MediaItem.t()) :: [atom()]
  def compatible_library_types(%Episode{}), do: [:series, :mixed]
  def compatible_library_types(%MediaItem{type: "movie"}), do: [:movies, :mixed]

  defp normalize_query(q) when is_binary(q) do
    case String.trim(q) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_query(_q), do: nil

  defp item_of(%Episode{media_item: %MediaItem{} = show}), do: show
  defp item_of(%MediaItem{} = movie), do: movie

  defp media_type(%Episode{}), do: "tv_show"
  defp media_type(%MediaItem{type: type}), do: type

  defp pool_query(target, {provider_type, provider_id}, query) do
    types = compatible_library_types(target)
    type = media_type(target)

    # A path some media_files row owns (trashed included) can never be
    # attached, so it is never offered, whatever stale candidate remains.
    owned =
      from(f in MediaFile,
        where:
          f.library_path_id == parent_as(:candidate).library_path_id and
            f.relative_path == parent_as(:candidate).relative_path
      )

    from(c in ImportCandidate, as: :candidate)
    |> join(:inner, [c], lp in assoc(c, :library_path))
    |> where(
      [c, lp],
      lp.type in ^types and (lp.disabled == false or is_nil(lp.disabled)) and
        is_nil(c.queued_op) and (is_nil(c.media_type) or c.media_type == ^type)
    )
    |> where(not exists(owned))
    |> identity_first(provider_type, provider_id)
    |> narrow(target, provider_type, provider_id, query)
    |> limit(@pool_cap)
    |> preload([_c, lp], library_path: lp)
  end

  defp identity_first(query, provider_type, provider_id)
       when is_binary(provider_type) and is_binary(provider_id) do
    order_by(query, [c],
      desc:
        fragment(
          "CASE WHEN ? = ? AND ? = ? THEN 1 ELSE 0 END",
          c.provider_type,
          ^provider_type,
          c.provider_id,
          ^provider_id
        ),
      desc: c.discovered_at
    )
  end

  defp identity_first(query, _provider_type, _provider_id),
    do: order_by(query, [c], desc: c.discovered_at)

  # With a typed query the path LIKE is the filter; otherwise prefilter in SQL
  # to identity matches or paths containing a significant title token, so we
  # never load and parse the whole table.
  defp narrow(query, _target, _type, _id, q) when is_binary(q) do
    like = "%" <> ImportCandidates.escape_like(q) <> "%"
    where(query, [c], fragment("LOWER(?) LIKE LOWER(?) ESCAPE '\\'", c.relative_path, ^like))
  end

  defp narrow(query, target, provider_type, provider_id, nil) do
    identity =
      if is_binary(provider_type) and is_binary(provider_id),
        do: dynamic([c], c.provider_type == ^provider_type and c.provider_id == ^provider_id),
        else: dynamic(false)

    tokens = title_tokens(item_of(target))

    filter =
      Enum.reduce(tokens, identity, fn token, acc ->
        like = "%" <> ImportCandidates.escape_like(token) <> "%"

        dynamic(
          [c],
          ^acc or fragment("LOWER(?) LIKE LOWER(?) ESCAPE '\\'", c.relative_path, ^like)
        )
      end)

    where(query, ^filter)
  end

  defp title_tokens(%MediaItem{title: title}) when is_binary(title) do
    title
    |> Text.match_tokens()
    |> Enum.filter(&(String.length(&1) >= @min_token_length))
    |> Enum.uniq()
    |> Enum.take(@max_tokens)
  end

  defp title_tokens(_item), do: []

  defp searching?(q), do: is_binary(q)

  defp score(candidate, target, item, identity) do
    parsed = ReleaseParser.parse(Path.basename(candidate.relative_path))

    episode = episode_reason(candidate, parsed, target)

    # A show's provider id says nothing about which episode a file is, so for
    # an episode target identity only counts alongside the episode hit.
    provider =
      if match?(%Episode{}, target) and is_nil(episode),
        do: nil,
        else: same_provider(candidate, identity)

    reasons =
      [
        provider,
        title_reason(candidate, parsed, item),
        year_reason(candidate, parsed, target, item),
        episode
      ]
      |> Enum.reject(&is_nil/1)

    %CandidateSuggestion{candidate: candidate, score: total(reasons), reasons: reasons}
  end

  defp same_provider(%ImportCandidate{provider_type: t, provider_id: id}, {t, id})
       when is_binary(t) and is_binary(id),
       do: :same_provider

  defp same_provider(_candidate, _identity), do: nil

  defp title_reason(candidate, parsed, item) do
    candidate_title = candidate.title || parsed.title

    case Text.title_similarity(item.title || "", candidate_title || "") do
      similarity when similarity > 0.0 -> {:title, similarity}
      _ -> nil
    end
  end

  defp year_reason(_candidate, _parsed, %Episode{}, _item), do: nil

  defp year_reason(candidate, parsed, _target, %MediaItem{year: year}) when is_integer(year) do
    if (candidate.year || parsed.year) == year, do: {:year, year}
  end

  defp year_reason(_candidate, _parsed, _target, _item), do: nil

  defp episode_reason(candidate, parsed, %Episode{} = episode) do
    info = candidate.parsed_info || %{}
    season = Map.get(info, "season") || parsed.season
    episodes = Map.get(info, "episodes") || parsed.episodes || []

    if season == episode.season_number and episode.episode_number in episodes,
      do: {:episode, episode.season_number, episode.episode_number}
  end

  defp episode_reason(_candidate, _parsed, _target), do: nil

  # Identity dominates; a title match is worth up to 1.0, a year or episode
  # hit adds a fixed bump that separates look-alikes.
  defp total(reasons) do
    Enum.reduce(reasons, 0.0, fn
      :same_provider, acc -> acc + 10.0
      {:title, similarity}, acc -> acc + similarity
      {:year, _}, acc -> acc + 0.5
      {:episode, _, _}, acc -> acc + 2.0
    end)
  end

  # Only identity, an episode hit or a strong title match make a file plausible;
  # a year alone merely adds to the score.
  defp plausible?(%CandidateSuggestion{reasons: reasons}) do
    Enum.any?(reasons, fn
      :same_provider -> true
      {:episode, _, _} -> true
      {:title, similarity} -> similarity >= @title_floor
      _other -> false
    end)
  end
end
