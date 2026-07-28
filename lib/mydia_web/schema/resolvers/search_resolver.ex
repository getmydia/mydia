defmodule MydiaWeb.Schema.Resolvers.SearchResolver do
  @moduledoc """
  Resolver for the library search query.

  Delegates to `Mydia.LibrarySearch`, which owns matching, ranking, and
  authorization. This module's only jobs are reading the authenticated user out
  of the Absinthe context and turning raw image paths into URLs.

  An unauthenticated request errors rather than falling back to unscoped
  results, because the collections section is user-scoped.
  """

  alias Mydia.Accounts.User
  alias Mydia.LibrarySearch
  alias Mydia.LibrarySearch.{Result, Results, Section}
  alias Mydia.Metadata.ImageUrl

  @spec search(map(), map(), Absinthe.Resolution.t()) :: {:ok, term()} | {:error, term()}
  def search(_parent, %{query: query} = args, %{context: %{current_user: %User{} = user}}) do
    opts = [limit: Map.get(args, :first, 20)]
    opts = if types = Map.get(args, :types), do: Keyword.put(opts, :types, types), else: opts

    with {:ok, %Results{} = results} <- LibrarySearch.search(user, query, opts) do
      {:ok,
       %{
         sections: Enum.map(results.sections, &build_section/1),
         total_count: results.total_count
       }}
    end
  end

  def search(_parent, _args, _info), do: {:error, :unauthenticated}

  defp build_section(%Section{} = section) do
    %{
      type: section.type,
      results: Enum.map(section.results, &build_result/1),
      total_count: section.total_count
    }
  end

  defp build_result(%Result{} = result) do
    %{
      id: result.id,
      type: result.type,
      title: result.title,
      year: result.year,
      score: result.score,
      subtitle: result.subtitle,
      season_number: result.season_number,
      episode_number: result.episode_number,
      parent_id: result.parent_id,
      artwork: build_artwork(result)
    }
  end

  defp build_artwork(%Result{poster_path: nil, backdrop_path: nil, still_path: nil}), do: nil

  defp build_artwork(%Result{} = result) do
    %{
      poster_url: ImageUrl.poster_url(result.poster_path),
      backdrop_url: ImageUrl.backdrop_url(result.backdrop_path),
      thumbnail_url: ImageUrl.still_url(result.still_path)
    }
  end
end
