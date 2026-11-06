defmodule MydiaWeb.DiscoverLive.People do
  @moduledoc """
  Discover's People type (`?type=person`): TMDB's popular people with no
  query, people matching the query with one, both paged in by the shared
  load-more sentinel.

  Assigns owned here: `:people`, `:people_page`, `:people_has_more`,
  `:people_loading_more`, `:people_error` (the first page failed) and
  `:people_more_error` (a later page failed). It also sets the page-wide
  `:loading` while the first page is out.
  """

  require Logger

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1, push_patch: 2, start_async: 3]

  alias Mydia.Accounts.Scope
  alias Mydia.Metadata
  alias Mydia.Metadata.People
  alias Mydia.Metadata.Structs.PersonPage

  @doc """
  Discover's `handle_params/3` for a People URL: `?type=person`, or an
  18.beta.3 link that made People a scope of the title search
  (`?q=...&scope=people`). The old link renders People straight away and, once
  connected, has its URL patched onto the People type.
  """
  def handle_params(%{"scope" => "people", "q" => query}, socket) do
    query = String.trim(query)

    if connected?(socket),
      do:
        {:noreply,
         push_patch(socket, to: "/discover?" <> URI.encode_query(params(query)), replace: true)},
      else: handle_params(params(query), socket)
  end

  def handle_params(%{"type" => "person"} = params, socket) do
    query = params["q"] || ""

    # The title-only assigns are reset too: the template still reads them,
    # and a value left from Movies (a filter, a See all source) must not leak.
    socket =
      socket
      |> assign(:media_type, :person)
      |> assign(:category, :trending)
      |> assign(:categories, [])
      |> assign(:search_query, query)
      |> assign(:search_mode, query != "")
      |> assign(:selected_genres, [])
      |> assign(:selected_language, nil)
      |> assign(:year_from, nil)
      |> assign(:year_to, nil)
      |> assign(:min_rating, nil)
      |> assign(:sort_by, "popularity.desc")
      |> assign(:source, nil)
      |> assign(:regional_sources, [])
      |> assign(:regional_rows, %{})
      |> assign(:items, [])
      |> assign(:visible_items, [])
      |> assign(:has_more, false)
      |> assign(:load_error, nil)
      |> assign(:loading, true)
      |> reset()

    if connected?(socket), do: send(self(), :load_data)

    {:noreply, socket}
  end

  @doc "Clears every people assign."
  def reset(socket) do
    socket
    |> assign(:people, [])
    |> assign(:people_page, 0)
    |> assign(:people_has_more, false)
    |> assign(:people_loading_more, false)
    |> assign(:people_error, nil)
    |> assign(:people_more_error, nil)
  end

  @doc "The Discover URL params for People, with or without a query."
  def params(""), do: %{"type" => "person"}
  def params(query), do: %{"type" => "person", "q" => query}

  @doc """
  Starts loading the first page; `handle_result/2` stores it and clears
  `:loading`.

  Through `start_async/3`: on a cache miss this is a relay call with the
  config's timeout, and switching away would otherwise queue behind it. A later
  `start_async/3` under the same name replaces an earlier one's result, so a
  new query or Retry never shows a stale page.
  """
  def load(socket) do
    socket
    |> reset()
    |> assign(:loading, true)
    |> fetch(1)
  end

  @doc """
  Discover's `handle_info/2` while on People. `:load_data` loads the first
  page. A titles `{:load_page, ...}` is dropped: hide-owned and restricted
  viewers chain those, and one can still be queued when the user switches to
  People, where it would fetch titles for a `:person` media type.
  """
  def handle_info(:load_data, socket), do: load(socket)
  def handle_info({:load_page, _page, _advances, _target}, socket), do: socket

  @doc "The error state's Try again: reloads the first page, on People only."
  def retry(%{assigns: %{media_type: :person}} = socket), do: load(socket)
  def retry(socket), do: socket

  @doc "Starts loading the next page, unless one is out or there is none."
  def load_more(%{assigns: %{people_has_more: true, people_loading_more: false}} = socket) do
    socket
    |> assign(:people_loading_more, true)
    |> assign(:people_more_error, nil)
    |> fetch(socket.assigns.people_page + 1)
  end

  def load_more(socket), do: socket

  defp fetch(socket, page) do
    config =
      Map.get_lazy(socket.assigns, :metadata_config, &Metadata.default_relay_config/0)

    query = socket.assigns.search_query

    start_async(socket, :people, fn -> {query, page, request(config, query, page)} end)
  end

  defp request(config, "", page), do: People.popular_people_cached(config, page: page)
  defp request(config, query, page), do: People.search_people_cached(config, query, page: page)

  @doc """
  Stores a page, unless the user has since left People or changed the query.

  The popular ranking shifts between requests, so a later page can repeat
  someone already shown; repeats are dropped rather than rendered twice.
  """
  def handle_result(socket, {:ok, {query, page, result}}) do
    case socket.assigns do
      %{media_type: :person, search_query: ^query} -> put_result(socket, page, result)
      _moved_on -> socket
    end
  end

  def handle_result(%{assigns: %{media_type: :person}} = socket, {:exit, reason}) do
    page = if socket.assigns.people_loading_more, do: socket.assigns.people_page + 1, else: 1
    put_result(socket, page, {:error, {:exit, reason}})
  end

  def handle_result(socket, {:exit, _reason}), do: socket

  defp put_result(socket, page, {:ok, %PersonPage{} = result}) do
    restricted? = Scope.restricted?(socket.assigns.current_scope)

    incoming =
      Enum.map(result.results, fn person ->
        if restricted?, do: %{person | known_for: []}, else: person
      end)

    shown = if page == 1, do: [], else: socket.assigns.people

    socket
    |> assign(:people, Enum.uniq_by(shown ++ incoming, & &1.tmdb_id))
    |> assign(:people_page, result.page)
    |> assign(:people_has_more, PersonPage.more?(result))
    |> assign(:people_loading_more, false)
    |> assign(:loading, false)
  end

  defp put_result(socket, page, {:error, reason}) do
    Logger.warning("Failed to load people page #{page}: #{inspect(reason)}")

    socket =
      if page == 1,
        do: socket |> reset() |> assign(:people_error, reason),
        else: assign(socket, :people_more_error, reason)

    socket
    |> assign(:people_loading_more, false)
    |> assign(:loading, false)
  end
end
