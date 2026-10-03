defmodule Mydia.Media.RemoteFilter do
  @moduledoc """
  Filters metadata provider results against a caller's access scope.

  These are titles that are not in the library, so there is no stored category
  or rating to filter on. Category is recovered by classifying the genre ids
  and origin signals TMDB returns with each hit, which costs no extra request.

  Rating is not in a search hit. For a restricted scope it comes from
  `Mydia.Media.RemoteSignals`, one cached lookup per title, so an age limit
  hides titles above it and titles with no certification. `discover_params/1`
  is only a pre-filter that narrows what TMDB returns on `/discover`.
  """

  alias Mydia.Accounts.Scope
  alias Mydia.Media.CategoryClassifier
  alias Mydia.Media.RemoteSignals
  alias Mydia.Media.Restrictions
  alias Mydia.Metadata
  alias Mydia.Metadata.Structs.SearchResult

  @doc """
  True when a search result may be shown to this scope.

  `signals` comes from `Mydia.Media.RemoteSignals`. Without them, an age
  limit refuses (a search hit carries no certification), and the category is
  classified from the hit's own genre and origin fields.
  """
  @spec allow?(SearchResult.t(), Scope.t(), RemoteSignals.t() | :error | nil) :: boolean()
  def allow?(result, scope, signals \\ nil)
  def allow?(_result, %Scope{allowed_categories: nil, max_content_age: nil}, _signals), do: true

  def allow?(%SearchResult{} = result, %Scope{} = scope, signals) do
    Restrictions.allowed?(category(result, signals), age(signals), scope)
  end

  @doc """
  Keeps only the results this scope may see, looking up certifications and
  categories as needed. Kept results carry `content_rating` when it is known.

  Options: `:config`, the relay config for lookups (tests inject Bypass).
  """
  @spec filter([SearchResult.t()], Scope.t(), keyword()) :: [SearchResult.t()]
  def filter(results, scope, opts \\ [])

  def filter(results, %Scope{allowed_categories: nil, max_content_age: nil}, _opts)
      when is_list(results),
      do: results

  def filter(results, %Scope{} = scope, opts) when is_list(results) do
    signals =
      results
      |> Enum.filter(&needs_lookup?(&1, scope))
      |> RemoteSignals.fetch_many(opts[:config])

    Enum.flat_map(results, fn result ->
      found = found_signals(signals, result)

      if allow?(result, scope, found), do: [with_rating(result, found)], else: []
    end)
  end

  # A result with no resolvable ref was never looked up, so it has no signals.
  # Under a category limit that needed them, it counts as a failed lookup.
  defp found_signals(signals, result) do
    case RemoteSignals.ref_for(result) do
      {:ok, ref} -> Map.get(signals, {result.media_type, ref})
      :error -> if no_signals?(result), do: :error
    end
  end

  defp needs_lookup?(_result, %Scope{max_content_age: age}) when not is_nil(age), do: true
  defp needs_lookup?(result, %Scope{allowed_categories: [_ | _]}), do: no_signals?(result)
  defp needs_lookup?(_result, _scope), do: false

  defp no_signals?(%SearchResult{genre_ids: [], origin_country: [], original_language: nil}),
    do: true

  defp no_signals?(_result), do: false

  defp category(_result, %RemoteSignals{category: category}) when is_binary(category),
    do: category

  # The lookup failed for a hit with nothing to classify from: unknown, which
  # a category limit refuses.
  defp category(result, :error), do: if(no_signals?(result), do: nil, else: classify(result))
  defp category(result, _signals), do: classify(result)

  defp age(%RemoteSignals{age: age}), do: age
  defp age(_signals), do: nil

  defp with_rating(result, %RemoteSignals{content_rating: rating}),
    do: %{result | content_rating: rating}

  defp with_rating(result, _signals), do: result

  defp classify(result) do
    result.media_type
    |> CategoryClassifier.classify_from_metadata(%{
      genres: genre_names(result.genre_ids, result.media_type),
      origin_country: result.origin_country,
      original_language: result.original_language
    })
    |> to_string()
  end

  @doc """
  Extra TMDB discover parameters implied by a scope's age limit.

  Returns an empty list when the scope sets no limit. TMDB expresses this as a
  certification ceiling in one country's system rather than as an age, so this
  maps the age back onto the US ladder.
  """
  @spec discover_params(Scope.t()) :: keyword()
  def discover_params(%Scope{max_content_age: nil}), do: []

  def discover_params(%Scope{max_content_age: age}) do
    [certification_country: "US", certification_lte: us_certification(age)]
  end

  defp us_certification(age) when age < 8, do: "G"
  defp us_certification(age) when age < 13, do: "PG"
  defp us_certification(age) when age < 17, do: "PG-13"
  defp us_certification(17), do: "R"
  defp us_certification(_age), do: "NC-17"

  # `Mydia.Metadata.genres/1` returns atom-keyed maps, built by
  # `Relay.fetch_genres/2`. Reading them with `genre["id"]` returns nil for
  # every entry, which would classify every result as unclassified and hide the
  # whole discover page from a restricted account while looking like it worked.
  defp genre_names([], _media_type), do: []

  defp genre_names(genre_ids, media_type) do
    case Metadata.genres(media_type) do
      {:ok, genres} ->
        by_id = Map.new(genres, fn genre -> {genre.id, genre.name} end)
        Enum.flat_map(genre_ids, fn id -> List.wrap(Map.get(by_id, id)) end)

      _ ->
        []
    end
  end
end
