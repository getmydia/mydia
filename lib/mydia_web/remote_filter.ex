defmodule MydiaWeb.RemoteFilter do
  @moduledoc """
  Filters metadata provider results against a caller's access scope.

  These are titles that are not in the library, so there is no stored category
  or rating to filter on. Category is recovered by classifying the genre ids
  and origin signals TMDB returns with each hit, which costs no extra request.

  Rating is not recoverable this way. TMDB search returns no certification and
  exposes no parameter to filter by one, so a search hit above an account's age
  limit still appears on `/request`. Nothing reaches the library from there
  without an admin approving the request, which is the control that actually
  holds. `/discover` is different: TMDB's discover endpoint does take a
  certification ceiling, so `discover_params/1` applies the limit there.
  """

  alias Mydia.Accounts.Scope
  alias Mydia.Media.CategoryClassifier
  alias Mydia.Metadata
  alias Mydia.Metadata.Structs.SearchResult

  @doc """
  True when a search result may be shown to this scope.
  """
  @spec allow?(SearchResult.t(), Scope.t()) :: boolean()
  def allow?(_result, %Scope{allowed_categories: nil}), do: true

  def allow?(%SearchResult{} = result, %Scope{allowed_categories: categories}) do
    category =
      result.media_type
      |> CategoryClassifier.classify_from_metadata(%{
        genres: genre_names(result.genre_ids, result.media_type),
        origin_country: result.origin_country,
        original_language: result.original_language
      })
      |> to_string()

    category in categories
  end

  @doc """
  Keeps only the results this scope is allowed to see.
  """
  @spec filter([SearchResult.t()], Scope.t()) :: [SearchResult.t()]
  def filter(results, %Scope{allowed_categories: nil}) when is_list(results), do: results

  def filter(results, %Scope{} = scope) when is_list(results) do
    Enum.filter(results, &allow?(&1, scope))
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
  defp us_certification(_age), do: "R"

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
