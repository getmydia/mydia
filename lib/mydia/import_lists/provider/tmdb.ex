defmodule Mydia.ImportLists.Provider.TMDB do
  @moduledoc """
  TMDB list provider for import lists.

  Fetches items from various TMDB curated lists via the metadata-relay service:
  - Trending (movies and TV)
  - Popular (movies and TV)
  - Upcoming movies
  - Now Playing movies
  - On The Air TV shows
  - Airing Today TV shows
  - User-created TMDB lists
  """

  @behaviour Mydia.ImportLists.Provider

  require Logger
  alias Mydia.Metadata.Provider.HTTP
  alias Mydia.ImportLists.ImportList

  @supported_types ~w(
    tmdb_trending
    tmdb_popular
    tmdb_upcoming
    tmdb_now_playing
    tmdb_on_the_air
    tmdb_airing_today
    tmdb_list
  )

  # Maximum number of pages to fetch from a single TMDB relay endpoint. TMDB
  # curated endpoints return roughly 20 items per page, so 5 pages caps a
  # single sync at ~100 items instead of the 20 a single-page fetch used to
  # cap it at.
  @max_pages 5

  defmodule Source do
    @moduledoc false
    # The parts of a paginated fetch that stay put across the recursion, so
    # only the page cursor and accumulator get threaded through it.
    defstruct [:req, :endpoint, :results_key, :status_error_fn, :require_metadata?]

    @type t :: %__MODULE__{
            req: Req.Request.t(),
            endpoint: String.t(),
            results_key: String.t(),
            status_error_fn: (integer(), term() -> String.t()),
            require_metadata?: boolean()
          }
  end

  @impl true
  def supports?(type), do: type in @supported_types

  @impl true
  def fetch_items(%ImportList{type: "tmdb_list"} = import_list) do
    config = get_config()
    list_id = extract_list_id(import_list.config)

    case list_id do
      nil ->
        {:error, "No list ID configured"}

      id ->
        fetch_user_list(config, id, import_list.media_type)
    end
  end

  def fetch_items(%ImportList{} = import_list) do
    config = get_config()

    case fetch_from_endpoint(config, import_list.type, import_list.media_type) do
      {:ok, results} ->
        items = Enum.map(results, &parse_result(&1, import_list.media_type))
        {:ok, items}

      {:error, reason} ->
        Logger.error("Failed to fetch TMDB list items",
          type: import_list.type,
          media_type: import_list.media_type,
          error: inspect(reason)
        )

        {:error, reason}
    end
  end

  ## Private Functions

  defp get_config do
    Mydia.Metadata.default_relay_config()
  end

  # Extract list ID from config - handles both raw ID and full URL
  defp extract_list_id(nil), do: nil

  defp extract_list_id(%{"list_url" => url}) when is_binary(url),
    do: extract_list_id_from_url(url)

  defp extract_list_id(_), do: nil

  defp extract_list_id_from_url(url) do
    cond do
      # Pure numeric ID
      Regex.match?(~r/^\d+$/, url) ->
        url

      # Full TMDB URL like https://www.themoviedb.org/list/12345
      String.contains?(url, "themoviedb.org/list/") ->
        case Regex.run(~r{/list/(\d+)}, url) do
          [_, id] -> id
          _ -> nil
        end

      true ->
        nil
    end
  end

  defp fetch_user_list(config, list_id, media_type) do
    endpoint = "/tmdb/list/#{list_id}"
    req = HTTP.new_request(config)

    status_error_fn = fn
      404, _body -> "TMDB list not found (ID: #{list_id})"
      status, body -> "API returned status #{status}: #{inspect(body)}"
    end

    # The user-list endpoint may or may not paginate like the curated
    # endpoints do. `require_pagination_metadata?: true` means we only
    # follow to a second page when the first page's response actually
    # reports `total_pages`; otherwise we treat it as a single, unpaginated
    # response, matching the previous single-request behavior.
    case fetch_paginated(req, endpoint, "items", status_error_fn,
           require_pagination_metadata?: true
         ) do
      {:ok, items} ->
        filtered_items =
          items
          |> Enum.filter(&matches_media_type?(&1, media_type))
          |> Enum.map(&parse_result(&1, media_type))

        {:ok, filtered_items}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Check if a TMDB item matches the expected media type
  defp matches_media_type?(%{"media_type" => "movie"}, "movie"), do: true
  defp matches_media_type?(%{"media_type" => "tv"}, "tv_show"), do: true
  # If no media_type field, include it (let user decide)
  defp matches_media_type?(%{"media_type" => nil}, _), do: true
  defp matches_media_type?(item, _) when not is_map_key(item, "media_type"), do: true
  defp matches_media_type?(_, _), do: false

  defp fetch_from_endpoint(config, type, media_type) do
    with {:ok, endpoint} <- build_endpoint(type, media_type) do
      req = HTTP.new_request(config)
      status_error_fn = fn status, body -> "API returned status #{status}: #{inspect(body)}" end

      fetch_paginated(req, endpoint, "results", status_error_fn,
        require_pagination_metadata?: false
      )
    end
  end

  # Fetches up to @max_pages pages from `endpoint`, concatenating the list
  # found under `results_key` in each page's body. Stops early when a page
  # comes back empty, when a page has fewer items than the previous page
  # (the previous page was the last full one), or when the response's own
  # `total_pages` says the last page has been reached.
  #
  # When `require_pagination_metadata?: true`, a first page with no
  # `total_pages` in its body is treated as the only page: the endpoint is
  # assumed not to paginate, and no further pages are requested.
  #
  # If the first page fails, the whole fetch fails. If a later page fails,
  # the items already gathered are returned and a warning is logged, so a
  # transient failure partway through does not fail the entire sync.
  defp fetch_paginated(req, endpoint, results_key, status_error_fn, opts) do
    source = %Source{
      req: req,
      endpoint: endpoint,
      results_key: results_key,
      status_error_fn: status_error_fn,
      require_metadata?: Keyword.fetch!(opts, :require_pagination_metadata?)
    }

    do_fetch_paginated(source, 1, [], nil)
  end

  defp do_fetch_paginated(%Source{}, page, acc, _prev_count) when page > @max_pages do
    {:ok, acc}
  end

  defp do_fetch_paginated(%Source{} = source, page, acc, prev_count) do
    %Source{req: req, endpoint: endpoint, results_key: results_key} = source
    params = [language: "en-US", page: page]

    case HTTP.get(req, endpoint, params: params) do
      {:ok, %{status: 200, body: %{^results_key => items} = body}} when is_list(items) ->
        continue_pagination(source, page, acc, prev_count, items, body["total_pages"])

      {:ok, %{status: 200, body: body}} ->
        Logger.warning("Unexpected TMDB response format", endpoint: endpoint, body: inspect(body))
        {:ok, acc}

      {:ok, %{status: status, body: body}} ->
        handle_page_error(page, acc, source.status_error_fn.(status, body))

      {:error, error} ->
        handle_page_error(page, acc, error)
    end
  end

  defp continue_pagination(%Source{} = source, page, acc, prev_count, items, total_pages) do
    new_acc = acc ++ items

    cond do
      items == [] ->
        {:ok, acc}

      is_integer(prev_count) and length(items) < prev_count ->
        {:ok, new_acc}

      is_integer(total_pages) and page >= total_pages ->
        {:ok, new_acc}

      is_nil(total_pages) and source.require_metadata? ->
        {:ok, new_acc}

      page >= @max_pages ->
        {:ok, new_acc}

      true ->
        do_fetch_paginated(source, page + 1, new_acc, length(items))
    end
  end

  defp handle_page_error(1, _acc, reason), do: {:error, reason}

  defp handle_page_error(page, acc, reason) do
    Logger.warning("TMDB pagination request failed; returning items gathered so far",
      page: page,
      error: inspect(reason)
    )

    {:ok, acc}
  end

  defp build_endpoint("tmdb_trending", "movie"), do: {:ok, "/tmdb/movies/trending"}
  defp build_endpoint("tmdb_trending", "tv_show"), do: {:ok, "/tmdb/tv/trending"}
  defp build_endpoint("tmdb_popular", "movie"), do: {:ok, "/tmdb/movies/popular"}
  defp build_endpoint("tmdb_popular", "tv_show"), do: {:ok, "/tmdb/tv/popular"}
  defp build_endpoint("tmdb_upcoming", "movie"), do: {:ok, "/tmdb/movies/upcoming"}
  defp build_endpoint("tmdb_now_playing", "movie"), do: {:ok, "/tmdb/movies/now_playing"}
  defp build_endpoint("tmdb_on_the_air", "tv_show"), do: {:ok, "/tmdb/tv/on_the_air"}
  defp build_endpoint("tmdb_airing_today", "tv_show"), do: {:ok, "/tmdb/tv/airing_today"}

  # Invalid combination (e.g. a movie-only type with media_type "tv_show").
  # Fail loudly instead of silently falling back to trending movies: a caller
  # storing this reason should recognize it as configuration error, not a
  # transient failure.
  defp build_endpoint(type, media_type) do
    {:error,
     "Invalid TMDB list type/media_type combination: #{inspect(type)} does not support media_type #{inspect(media_type)}"}
  end

  defp parse_result(result, media_type) do
    # Extract year from release_date or first_air_date
    year = extract_year(result)

    %{
      tmdb_id: result["id"],
      title: result["title"] || result["name"],
      year: year,
      poster_path: result["poster_path"],
      media_type: media_type
    }
  end

  defp extract_year(%{"release_date" => date}) when is_binary(date) and byte_size(date) >= 4 do
    case Integer.parse(String.slice(date, 0, 4)) do
      {year, _} -> year
      :error -> nil
    end
  end

  defp extract_year(%{"first_air_date" => date}) when is_binary(date) and byte_size(date) >= 4 do
    case Integer.parse(String.slice(date, 0, 4)) do
      {year, _} -> year
      :error -> nil
    end
  end

  defp extract_year(_), do: nil
end
