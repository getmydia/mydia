defmodule Mydia.Media.Recommendations do
  @moduledoc """
  Resolves TMDB's recommendations for a title.

  Serves two surfaces with different inputs: the library detail page, which has a
  `MediaItem` row, and the Discover modal, which has only a TMDB id and a type
  because the title is not in the library.

  Every outcome that is not a non-empty list collapses to `:none` — no tmdb_id,
  an unsupported media type, an empty result, a relay error. The rail is meant to
  be silently absent whenever the lookup does not work out, so the caller has
  exactly one thing to check.

  Results are deliberately **not** joined against the library here. That join
  needs `MydiaWeb.Live.Helpers.MediaAddHelpers`, and a context under `Mydia.*`
  must not depend on the web layer, so the LiveViews enrich what they render.
  """

  require Logger

  alias Mydia.Media.MediaItem
  alias Mydia.Metadata
  alias Mydia.Metadata.Structs.SearchResult

  @media_types %{"movie" => :movie, "tv_show" => :tv_show}

  # TMDB returns up to 20 recommendations in an order of its own. Twelve ranked
  # entries is roughly one screen of horizontal scroll past what a typical
  # content column shows; twenty is nearly two.
  @rail_limit 12

  # Prior weight for the Bayesian rating. An entry needs roughly this many votes
  # before its own average outweighs the set mean, which is what stops a 10.0
  # from three voters leading the rail.
  @min_votes 50

  @doc """
  Returns recommendations for a library item, or `:none`.

  `config` is the relay configuration; it defaults to
  `Metadata.default_relay_config/0` and exists so tests can inject a stub without
  touching global environment.
  """
  @spec for_media_item(MediaItem.t(), map() | nil) :: {:ok, [SearchResult.t()]} | :none
  def for_media_item(media_item, config \\ nil)

  def for_media_item(%MediaItem{type: type, tmdb_id: tmdb_id}, config)
      when is_integer(tmdb_id) and is_map_key(@media_types, type) do
    for_tmdb_id(tmdb_id, Map.fetch!(@media_types, type), config)
  end

  def for_media_item(_media_item, _config), do: :none

  @doc """
  Returns recommendations for a bare TMDB id, or `:none`.

  This is the entry point for the Discover modal, where the title has no
  `MediaItem` row because it is not in the library.
  """
  @spec for_tmdb_id(integer() | String.t() | nil, :movie | :tv_show, map() | nil) ::
          {:ok, [SearchResult.t()]} | :none
  def for_tmdb_id(tmdb_id, media_type, config \\ nil)

  def for_tmdb_id(nil, _media_type, _config), do: :none

  def for_tmdb_id(tmdb_id, media_type, config) when media_type in [:movie, :tv_show] do
    case normalize_tmdb_id(tmdb_id) do
      {:ok, tmdb_id} -> fetch(tmdb_id, media_type, config)
      :error -> :none
    end
  end

  def for_tmdb_id(_tmdb_id, _media_type, _config), do: :none

  @doc """
  Orders recommendations by Bayesian weighted rating and caps the list.

  `WR = (v / (v + m)) * R + (m / (v + m)) * C`, where `R` is the entry's rating,
  `v` its vote count, `m` is `@min_votes`, and `C` the mean rating of the rated
  entries in this set. Deriving `C` from the set itself avoids carrying a global
  TMDB average that would silently rot.

  An unrated entry scores exactly `C` and lands mid-pack. Ties fall back to
  TMDB's own order so the result is deterministic under test.

  Public so the ranking can be exercised without a relay round trip.
  """
  @spec rank([SearchResult.t()]) :: [SearchResult.t()]
  def rank(results) when is_list(results) do
    case mean_rating(results) do
      # Nothing in the set has a vote, so there is no signal to sort on. Keep
      # TMDB's order and apply the cap alone.
      nil ->
        Enum.take(results, @rail_limit)

      mean ->
        results
        |> Enum.with_index()
        |> Enum.sort_by(fn {result, index} -> {-weighted_rating(result, mean), index} end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.take(@rail_limit)
    end
  end

  # `""` and `"abc"` would otherwise be interpolated straight into a relay path
  # and spend a request to learn what the shape already tells us.
  defp normalize_tmdb_id(id) when is_integer(id) and id > 0, do: {:ok, to_string(id)}

  defp normalize_tmdb_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} when parsed > 0 -> {:ok, to_string(parsed)}
      _ -> :error
    end
  end

  defp normalize_tmdb_id(_), do: :error

  defp fetch(tmdb_id, media_type, config) do
    config = config || Metadata.default_relay_config()

    case Metadata.fetch_recommendations_cached(config, tmdb_id, media_type: media_type) do
      {:ok, []} ->
        :none

      {:ok, results} when is_list(results) ->
        {:ok, rank(results)}

      {:error, reason} ->
        Logger.warning(
          "Recommendations lookup failed for tmdb #{tmdb_id} (#{media_type}): #{inspect(reason)}"
        )

        :none
    end
  end

  defp mean_rating(results) do
    case Enum.filter(results, &rated?/1) do
      [] -> nil
      rated -> Enum.sum(Enum.map(rated, &rating/1)) / length(rated)
    end
  end

  # An entry needs both a numeric rating and at least one vote before it can
  # inform the mean. Treating a nil rating as 0.0 would drag the prior down for
  # every other entry in the set. Pattern-matched, like rating/1 and votes/1
  # below, so a loose map missing :vote_average entirely falls to the
  # catch-all instead of raising KeyError on the dot access.
  defp rated?(%{vote_average: value} = result) when is_number(value),
    do: votes(result) > 0

  defp rated?(_result), do: false

  defp weighted_rating(result, mean) do
    if rated?(result) do
      v = votes(result)

      v / (v + @min_votes) * rating(result) + @min_votes / (v + @min_votes) * mean
    else
      # No usable rating, so the honest score is the set mean: mid-pack.
      mean
    end
  end

  defp rating(%{vote_average: value}) when is_number(value), do: value / 1
  defp rating(_result), do: 0.0

  defp votes(%{vote_count: value}) when is_integer(value) and value > 0, do: value
  defp votes(_result), do: 0
end
