defmodule MydiaWeb.DiscoverLive.PeopleSearch do
  @moduledoc """
  Discover's People search scope: the scope assigns, the URL params that carry
  it, and the lookup behind the results grid.

  Assigns owned here: `:search_scope` (`:titles` or `:people`),
  `:people_results` and `:people_error`.
  """

  require Logger

  import Phoenix.Component, only: [assign: 3]

  alias Mydia.Metadata
  alias Mydia.Metadata.People

  @doc "Sets the scope and clears any earlier people results."
  def assign_scope(socket, scope) when scope in [:titles, :people] do
    socket
    |> assign(:search_scope, scope)
    |> assign(:people_results, [])
    |> assign(:people_error, nil)
  end

  @doc """
  The Discover URL params for a search. A new query keeps the scope it was
  typed in; dropping `q` drops `scope` with it.
  """
  def params(media_type, query, :people),
    do: %{"type" => to_string(media_type), "q" => query, "scope" => "people"}

  def params(media_type, query, :titles), do: %{"type" => to_string(media_type), "q" => query}

  @doc """
  Searches people for the current query and clears `:loading`.

  The results are the first page of TMDB's person search only: no paging, and
  no access filtering, since a person carries no titles of their own here. The
  popup filters the person's titles when it opens.
  """
  def load(socket) do
    config =
      Map.get_lazy(socket.assigns, :metadata_config, &Metadata.default_relay_config/0)

    socket =
      case People.search_people_cached(config, socket.assigns.search_query) do
        {:ok, people} ->
          assign(socket, :people_results, people)

        {:error, reason} ->
          Logger.warning("Failed to search people: #{inspect(reason)}")
          socket |> assign(:people_results, []) |> assign(:people_error, reason)
      end

    assign(socket, :loading, false)
  end
end
