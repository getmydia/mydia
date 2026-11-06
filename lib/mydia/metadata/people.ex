defmodule Mydia.Metadata.People do
  @moduledoc """
  Fetches and searches TMDB people through the metadata relay.

  `fetch_person_cached/3`, `search_people_cached/3` and `popular_people_cached/2`
  are what callers use; `fetch_person/3`, `search_people/3` and
  `popular_people/2` are the uncached requests behind them.
  """

  alias Mydia.Metadata.Cache
  alias Mydia.Metadata.Provider.{Error, HTTP}
  alias Mydia.Metadata.Structs.{Person, PersonPage, PersonSearchResult}

  @default_language "en-US"

  @doc """
  Fetches a person with their filmography, cached in ETS for 24 hours.

  Relay-only, like `Mydia.Metadata.fetch_collection_cached/3`. The language is part
  of the key so a non-English library never reads English-cached biographies.
  """
  @spec fetch_person_cached(map(), integer(), keyword()) ::
          {:ok, Person.t()} | {:error, Error.t()}
  def fetch_person_cached(config, tmdb_id, opts \\ [])

  def fetch_person_cached(%{type: :metadata_relay} = config, tmdb_id, opts) do
    cache_key = "person:metadata_relay:#{tmdb_id}:#{language(config, opts)}"

    Cache.fetch(cache_key, fn -> fetch_person(config, tmdb_id, opts) end, ttl: :timer.hours(24))
  end

  def fetch_person_cached(%{type: type}, _tmdb_id, _opts) when is_atom(type),
    do: {:error, relay_only(type)}

  @doc """
  Searches TMDB people by name, cached in ETS for 24 hours.

  Relay-only, for the same reason as `fetch_person_cached/3`.
  """
  @spec search_people_cached(map(), String.t(), keyword()) ::
          {:ok, PersonPage.t()} | {:error, Error.t()}
  def search_people_cached(config, query, opts \\ [])

  def search_people_cached(%{type: :metadata_relay} = config, query, opts) do
    cache_key =
      "person_search:metadata_relay:#{query}:#{language(config, opts)}:#{page(opts)}"

    Cache.fetch(cache_key, fn -> search_people(config, query, opts) end, ttl: :timer.hours(24))
  end

  def search_people_cached(%{type: type}, _query, _opts) when is_atom(type),
    do: {:error, relay_only(type)}

  @doc """
  TMDB's popular people, cached in ETS for 24 hours.

  Relay-only, for the same reason as `fetch_person_cached/3`.
  """
  @spec popular_people_cached(map(), keyword()) :: {:ok, PersonPage.t()} | {:error, Error.t()}
  def popular_people_cached(config, opts \\ [])

  def popular_people_cached(%{type: :metadata_relay} = config, opts) do
    cache_key = "person_popular:metadata_relay:#{language(config, opts)}:#{page(opts)}"

    Cache.fetch(cache_key, fn -> popular_people(config, opts) end, ttl: :timer.hours(24))
  end

  def popular_people_cached(%{type: type}, _opts) when is_atom(type),
    do: {:error, relay_only(type)}

  defp relay_only(type) do
    Error.invalid_config(
      "People are only available through the metadata relay, got: #{inspect(type)}"
    )
  end

  @doc """
  Fetches a person with their combined credits.

  ## Options
    * `:language` - overrides the configured language
  """
  @spec fetch_person(map(), integer(), keyword()) :: {:ok, Person.t()} | {:error, Error.t()}
  def fetch_person(config, tmdb_id, opts \\ []) do
    params = [language: language(config, opts), append_to_response: "combined_credits"]

    case HTTP.get(HTTP.new_request(config), "/tmdb/person/#{tmdb_id}", params: params) do
      {:ok, %{status: 200, body: %{"id" => _} = body}} ->
        {:ok, Person.from_api_response(body)}

      {:ok, %{status: 200, body: _}} ->
        {:error, Error.api_error("Person response was not a person object")}

      {:ok, %{status: 404}} ->
        {:error, Error.not_found("Person not found: #{tmdb_id}")}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.api_error("Fetch person failed with status #{status}", %{body: body})}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Searches people by name. Adult results are always excluded.

  ## Options
    * `:page` - the 1-based page, default 1
    * `:language` - overrides the configured language
  """
  @spec search_people(map(), String.t(), keyword()) :: {:ok, PersonPage.t()} | {:error, Error.t()}
  def search_people(config, query, opts \\ []) do
    params = [
      query: query,
      language: language(config, opts),
      include_adult: false,
      page: page(opts)
    ]

    fetch_page(config, "/tmdb/person/search", params, "Person search")
  end

  @doc """
  Fetches one page of TMDB's popular people. Takes the same options as
  `search_people/3`.
  """
  @spec popular_people(map(), keyword()) :: {:ok, PersonPage.t()} | {:error, Error.t()}
  def popular_people(config, opts \\ []) do
    params = [language: language(config, opts), page: page(opts)]
    fetch_page(config, "/tmdb/person/popular", params, "Popular people")
  end

  # A body without `page` or `total_pages` reads as the requested page being
  # the last, so a short answer ends paging instead of asking forever.
  defp fetch_page(config, path, params, label) do
    requested = Keyword.fetch!(params, :page)

    case HTTP.get(HTTP.new_request(config), path, params: params) do
      {:ok, %{status: 200, body: %{} = body}} ->
        page = positive_integer(body["page"], requested)

        {:ok,
         %PersonPage{
           results: parse_results(body["results"]),
           page: page,
           total_pages: positive_integer(body["total_pages"], page)
         }}

      {:ok, %{status: 200}} ->
        {:ok, %PersonPage{results: [], page: requested, total_pages: requested}}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.api_error("#{label} failed with status #{status}", %{body: body})}

      {:error, error} ->
        {:error, error}
    end
  end

  defp parse_results(results) when is_list(results) do
    results
    |> Enum.filter(&match?(%{"id" => id} when is_integer(id), &1))
    |> Enum.map(&PersonSearchResult.from_api_response/1)
  end

  defp parse_results(_), do: []

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default

  defp page(opts), do: Keyword.get(opts, :page, 1)

  defp language(config, opts) do
    Keyword.get_lazy(opts, :language, fn ->
      case config do
        %{options: %{language: lang}} when is_binary(lang) and lang != "" -> lang
        _ -> @default_language
      end
    end)
  end
end
