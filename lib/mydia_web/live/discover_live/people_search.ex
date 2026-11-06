defmodule MydiaWeb.DiscoverLive.PeopleSearch do
  @moduledoc """
  Discover's People search scope: the scope assigns, the URL params that carry
  it, and the lookup behind the results grid.

  Assigns owned here: `:search_scope` (`:titles` or `:people`),
  `:people_results` and `:people_error`.
  """

  require Logger

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [start_async: 3]

  alias Mydia.Accounts.Scope
  alias Mydia.Metadata
  alias Mydia.Metadata.People
  alias Mydia.Metadata.Structs.PersonPage

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
  Starts the people search for the current query; `handle_result/2` stores it
  and clears `:loading`.

  Through `start_async/3` rather than inline: on a cache miss this is a relay
  call with the config's timeout, and switching scope or clearing the search
  would queue behind it.

  The results are the first page of TMDB's person search only: no paging. A
  person carries no titles of their own here, so the only access filtering is
  that a restricted viewer gets no known-for line: those titles are names only,
  with nothing the remote filter could judge them by. The popup filters the
  person's titles when it opens.
  """
  def load(socket) do
    config =
      Map.get_lazy(socket.assigns, :metadata_config, &Metadata.default_relay_config/0)

    query = socket.assigns.search_query

    socket
    |> assign(:loading, true)
    |> assign(:people_error, nil)
    |> start_async(:people_search, fn -> {query, People.search_people_cached(config, query)} end)
  end

  @doc """
  Stores a people search result, unless the user has since moved on to another
  query or to the Titles scope, whose own load owns `:loading` by then.
  """
  def handle_result(socket, {:ok, {query, result}}) do
    case socket.assigns do
      %{search_scope: :people, search_query: ^query} -> put_result(socket, result)
      _moved_on -> socket
    end
  end

  def handle_result(%{assigns: %{search_scope: :people}} = socket, {:exit, reason}),
    do: put_result(socket, {:error, {:exit, reason}})

  def handle_result(socket, {:exit, _reason}), do: socket

  defp put_result(socket, {:ok, %PersonPage{results: people}}) do
    people =
      if Scope.restricted?(socket.assigns.current_scope),
        do: Enum.map(people, &%{&1 | known_for: []}),
        else: people

    socket |> assign(:people_results, people) |> assign(:loading, false)
  end

  defp put_result(socket, {:error, reason}) do
    Logger.warning("Failed to search people: #{inspect(reason)}")

    socket
    |> assign(:people_results, [])
    |> assign(:people_error, reason)
    |> assign(:loading, false)
  end
end
