defmodule Mydia.Metadata.People do
  @moduledoc """
  Fetches and searches TMDB people through the metadata relay.

  Uncached; `Mydia.Metadata.fetch_person_cached/3` and
  `Mydia.Metadata.search_people_cached/3` add the cache.
  """

  alias Mydia.Metadata.Provider.{Error, HTTP}
  alias Mydia.Metadata.Structs.{Person, PersonSearchResult}

  @default_language "en-US"

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
    * `:language` - overrides the configured language
  """
  @spec search_people(map(), String.t(), keyword()) ::
          {:ok, [PersonSearchResult.t()]} | {:error, Error.t()}
  def search_people(config, query, opts \\ []) do
    params = [query: query, language: language(config, opts), include_adult: false]

    case HTTP.get(HTTP.new_request(config), "/tmdb/person/search", params: params) do
      {:ok, %{status: 200, body: %{"results" => results}}} when is_list(results) ->
        {:ok,
         results
         |> Enum.filter(&match?(%{"id" => id} when is_integer(id), &1))
         |> Enum.map(&PersonSearchResult.from_api_response/1)}

      {:ok, %{status: 200, body: _}} ->
        {:ok, []}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.api_error("Person search failed with status #{status}", %{body: body})}

      {:error, error} ->
        {:error, error}
    end
  end

  defp language(config, opts) do
    Keyword.get_lazy(opts, :language, fn ->
      case config do
        %{options: %{language: lang}} when is_binary(lang) and lang != "" -> lang
        _ -> @default_language
      end
    end)
  end
end
