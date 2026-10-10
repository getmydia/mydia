defmodule Mydia.Media.TitleMatch do
  @moduledoc """
  Recovers missing provider IDs by title search and scores search results against a media item.
  """

  require Logger
  alias Mydia.Accounts.Scope
  alias Mydia.Media.{Items, MediaItem}

  @doc """
  Recover TMDB ID by searching for the media item by title.

  This is useful when a media item was created without a provider ID (e.g., due to a bug)
  and needs to have its ID recovered via a title search.

  For TV shows, searches TVDB and stores tvdb_id. For movies, searches TMDB and stores tmdb_id.

  Pass `config` to reuse a caller's relay config; it defaults to
  `Metadata.default_relay_config/0`. A caller running against a specific relay
  must not have its recovery search silently fall back to the global default.

  Returns {:ok, provider_id, updated_media_item} or {:error, reason}
  """
  @spec recover_provider_id_by_title(MediaItem.t(), atom(), map() | nil) ::
          {:ok, integer(), MediaItem.t()} | {:error, term()}
  def recover_provider_id_by_title(%MediaItem{} = media_item, media_type, config \\ nil) do
    alias Mydia.Metadata
    config = config || Metadata.default_relay_config()
    do_recover_provider_id_by_title(media_item, media_type, config)
  end

  @doc false
  def do_recover_provider_id_by_title(%MediaItem{} = media_item, media_type, config) do
    alias Mydia.Metadata

    Logger.info("Attempting to recover provider ID by title search",
      media_item_id: media_item.id,
      title: media_item.title,
      media_type: media_type
    )

    search_opts =
      if media_item.year do
        [media_type: media_type, year: media_item.year]
      else
        [media_type: media_type]
      end

    case Metadata.search(config, media_item.title, search_opts) do
      {:ok, []} ->
        # Retry without year if no results
        if media_item.year do
          case Metadata.search(config, media_item.title, media_type: media_type) do
            {:ok, results} when results != [] ->
              select_and_update_provider_id(results, media_item, media_type)

            _ ->
              {:error, :no_matches_found}
          end
        else
          {:error, :no_matches_found}
        end

      {:ok, results} ->
        select_and_update_provider_id(results, media_item, media_type)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def select_and_update_provider_id(results, media_item, media_type) do
    alias Mydia.Metadata.Structs.SearchResult

    # Score and select best match
    scored_results =
      Enum.map(results, fn result ->
        score = calculate_title_match_score(result, media_item)
        {result, score}
      end)

    case Enum.max_by(scored_results, fn {_result, score} -> score end, fn -> nil end) do
      {%SearchResult{provider_id: provider_id, provider: provider}, score} when score >= 0.5 ->
        case Integer.parse(provider_id) do
          {parsed_id, ""} ->
            # For TV shows from TVDB, store as tvdb_id; otherwise store as tmdb_id
            {id_field, update_attrs} =
              if media_type == :tv_show and provider == :tvdb do
                {:tvdb_id, %{tvdb_id: parsed_id}}
              else
                {:tmdb_id, %{tmdb_id: parsed_id}}
              end

            Logger.info("Recovered provider ID via title search",
              media_item_id: media_item.id,
              title: media_item.title,
              id_field: id_field,
              provider_id: parsed_id,
              match_score: score
            )

            # Update the media item with the recovered ID
            case Items.update_media_item(Scope.system(), media_item, update_attrs,
                   reason: "Provider ID recovered"
                 ) do
              {:ok, updated_item} ->
                {:ok, parsed_id, updated_item}

              {:error, _changeset} ->
                # Even if update fails, return the ID so refresh can proceed
                {:ok, parsed_id, media_item}
            end

          _ ->
            {:error, :invalid_provider_id}
        end

      _ ->
        {:error, :no_confident_match}
    end
  end

  def calculate_title_match_score(result, media_item) do
    base_score = 0.5
    title_sim = title_similarity(result.title, media_item.title)

    score =
      base_score +
        title_sim * 0.25 +
        if(year_matches?(result.year, media_item.year), do: 0.15, else: 0.0) +
        if(exact_title_match?(result.title, media_item.title), do: 0.15, else: 0.0) +
        title_derivative_penalty(result.title, media_item.title)

    min(score, 1.0)
  end

  defp title_similarity(title1, title2) when is_binary(title1) and is_binary(title2) do
    norm1 = normalize_title(title1)
    norm2 = normalize_title(title2)

    cond do
      norm1 == norm2 -> 1.0
      String.contains?(norm1, norm2) or String.contains?(norm2, norm1) -> 0.8
      true -> String.jaro_distance(norm1, norm2)
    end
  end

  defp title_similarity(_title1, _title2), do: 0.0

  defp normalize_title(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^\w\s]/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  def exact_title_match?(result_title, search_title)
      when is_binary(result_title) and is_binary(search_title) do
    normalize_title(result_title) == normalize_title(search_title)
  end

  def exact_title_match?(_result_title, _search_title), do: false

  defp title_derivative_penalty(result_title, search_title)
       when is_binary(result_title) and is_binary(search_title) do
    norm_result = String.downcase(result_title) |> String.trim()
    norm_search = String.downcase(search_title) |> String.trim()

    if norm_result != norm_search and String.contains?(norm_result, norm_search) do
      search_len = String.length(norm_search)
      result_len = String.length(norm_result)
      extra_ratio = (result_len - search_len) / result_len
      -extra_ratio * 0.15
    else
      0.0
    end
  end

  defp title_derivative_penalty(_result_title, _search_title), do: 0.0

  def year_matches?(result_year, nil), do: result_year != nil
  def year_matches?(nil, _media_year), do: false

  def year_matches?(result_year, media_year) when is_integer(result_year) do
    abs(result_year - media_year) <= 1
  end

  def year_matches?(_result_year, _media_year), do: false
end
