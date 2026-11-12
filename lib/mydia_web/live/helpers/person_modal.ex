defmodule MydiaWeb.Live.Helpers.PersonModal do
  @moduledoc """
  Host-side state for `MydiaWeb.PersonComponents.person_modal/1`.

  Assigns owned here:

    * `:selected_person` - the fetched `Mydia.Metadata.Structs.Person`, or nil
    * `:person_stub` - `%{id, name, profile_path}` from the click, so the dialog
      can paint a header before the relay answers; nil when the dialog is closed
    * `:person_loading` - whether the fetch is in flight
    * `:person_error` - nil, or the reason the fetch failed
    * `:person_titles` - the person's credits as enriched `SearchResult`s, already
      narrowed to what the viewer may see and stamped with library and request
      status
    * `:person_status_stale` - whether an add or a request finished while the
      fetch was in flight, so the status it read is out of date

  A host calls `attach/1` from `mount/3` and renders the dialog; the lifecycle
  hooks it attaches answer the dialog's `show_person`, `close_person` and
  `retry_person` events and the `:load_person` async result, so the host defines
  no clauses for them. Opening a person closes the title dialog
  (`MydiaWeb.Live.Helpers.DetailModal`); a title opened from the person's
  posters stacks over the person instead. The host must have a `:current_scope`;
  a `:metadata_config` assign, when present, overrides the default relay config.
  """

  require Logger

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, start_async: 3, cancel_async: 2]

  alias Mydia.Accounts.Scope
  alias Mydia.Media
  alias Mydia.Media.RemoteFilter
  alias Mydia.Metadata
  alias Mydia.Metadata.People
  alias Mydia.Metadata.Structs.{Person, PersonCredit, SearchResult}
  alias MydiaWeb.Live.Helpers.{DetailModal, MediaAddHelpers, MediaRequestHelpers}

  @doc """
  Sets up a host: assigns the empty person state and attaches the event and
  async hooks. Call once from `mount/3`.
  """
  def attach(socket) do
    socket
    |> init()
    |> attach_hook(:person_modal_events, :handle_event, &handle_event/3)
    |> attach_hook(:person_modal_async, :handle_async, &handle_async/3)
  end

  defp handle_event("show_person", params, socket),
    do: {:halt, socket |> DetailModal.close() |> open(params)}

  defp handle_event("close_person", _params, socket), do: {:halt, close(socket)}
  defp handle_event("retry_person", _params, socket), do: {:halt, retry(socket)}
  defp handle_event(_event, _params, socket), do: {:cont, socket}

  defp handle_async(:load_person, result, socket), do: {:halt, handle_result(socket, result)}
  defp handle_async(_name, _result, socket), do: {:cont, socket}

  @doc """
  Assigns every person assign to its empty value.
  """
  def init(socket) do
    socket
    |> assign(:selected_person, nil)
    |> assign(:person_stub, nil)
    |> assign(:person_loading, false)
    |> assign(:person_error, nil)
    |> assign(:person_titles, [])
    |> assign(:person_status_stale, false)
  end

  @doc """
  Opens the dialog over the clicked person and starts the fetch.

  An id that is not a number returns the socket unchanged: the params come from
  the client, and there is nothing to open.
  """
  def open(socket, %{"id" => id} = params) do
    case parse_id(id) do
      {:ok, tmdb_id} ->
        stub = %{
          id: tmdb_id,
          name: params["name"],
          profile_path: blank_to_nil(params["profile_path"])
        }

        socket |> init() |> start_fetch(stub)

      :error ->
        socket
    end
  end

  def open(socket, _params), do: socket

  @doc """
  Re-runs the fetch for the person the dialog is open over.
  """
  def retry(%{assigns: %{person_stub: %{} = stub}} = socket), do: start_fetch(socket, stub)
  def retry(socket), do: socket

  @doc """
  Stores the fetch result, or records the failure.

  A successful result is `{person, titles}`: the fetch enriches the titles
  itself, off the LiveView process, so this only assigns.

  Returns the socket, not a `{:noreply, _}` tuple, so a host can pipe further.
  """
  def handle_result(%{assigns: %{person_stub: nil}} = socket, _result), do: socket

  def handle_result(
        %{assigns: %{person_stub: %{id: stub_id}}} = socket,
        {:ok, {:ok, {%Person{tmdb_id: id}, _titles}}}
      )
      when id != stub_id,
      do: socket

  def handle_result(socket, {:ok, {:ok, {%Person{} = person, titles}}}) when is_list(titles) do
    # The task read library and request status when it started. An add or a
    # request that finished while it ran asked for a refresh that had nothing to
    # refresh yet (see refresh_titles/1), so re-read the status for it now.
    titles =
      if socket.assigns.person_status_stale,
        do: put_status(titles, socket.assigns.current_scope),
        else: titles

    socket
    |> assign(:selected_person, person)
    |> assign(:person_titles, titles)
    |> assign(:person_loading, false)
    |> assign(:person_error, nil)
    |> assign(:person_status_stale, false)
  end

  def handle_result(socket, {:ok, {:error, reason}}), do: fail(socket, reason)
  def handle_result(socket, {:exit, reason}), do: fail(socket, {:exit, reason})
  def handle_result(socket, other), do: fail(socket, {:unexpected, other})

  @doc """
  Closes the dialog and resets every assign.

  Cancels the in-flight fetch too: a result landing after the dismissal would
  otherwise reopen the popup.
  """
  def close(socket), do: socket |> cancel_async(:load_person) |> init()

  @doc """
  The person's titles from a host's assigns, for hosts that resolve a
  `show_details` click against a selectable list. Empty for assigns built
  without the person state.

  The titles mix movies and shows, so a lookup against them must pass the media
  type: TMDB numbers the two catalogs independently.
  """
  def titles(assigns), do: Map.get(assigns, :person_titles, [])

  @doc """
  Re-reads the library and request status of the open person's titles.

  Call after an add or a request: without it a poster never gains its owned or
  requested badge. While the fetch is in flight it marks the status stale, and
  `handle_result/2` re-reads it when the titles land. A no-op while the dialog
  is closed.

  Only the status is re-read: the titles already passed the remote filter, and
  an add or a request does not change what the viewer may see. Re-filtering
  here would put the filter's relay lookups on the LiveView process.
  """
  def refresh_titles(%{assigns: %{selected_person: %Person{}}} = socket) do
    %{person_titles: titles, current_scope: scope} = socket.assigns
    assign(socket, :person_titles, put_status(titles, scope))
  end

  def refresh_titles(%{assigns: %{person_loading: true}} = socket),
    do: assign(socket, :person_status_stale, true)

  def refresh_titles(socket), do: socket

  @doc """
  The person's credits as `SearchResult`s the viewer may see, movies first, with
  library and request status.

  Movie and TV ids are looked up separately: a movie and a show can share a TMDB
  id, and the status map is keyed by media type.
  """
  @spec enrich_titles(Person.t(), Scope.t()) :: [SearchResult.t()]
  def enrich_titles(%Person{} = person, %Scope{} = scope) do
    (person.movie_credits ++ person.tv_credits)
    |> Enum.map(&PersonCredit.to_search_result/1)
    |> RemoteFilter.filter(scope)
    |> put_status(scope)
  end

  defp put_status(results, scope) do
    status =
      Map.merge(
        Media.library_status_for_tmdb_ids(scope, ids_of(results, :movie), "movie"),
        Media.library_status_for_tmdb_ids(scope, ids_of(results, :tv_show), "tv_show")
      )

    results
    |> MediaAddHelpers.enrich_with_library_status(status)
    |> MediaRequestHelpers.enrich_with_request_status(MediaRequestHelpers.request_status_map())
  end

  defp ids_of(results, type) do
    for %SearchResult{media_type: ^type, provider_id: id} <- results, do: String.to_integer(id)
  end

  # The enrichment runs in the task too: for a scope with a content-age limit
  # the remote filter looks up every credit, and a prolific person on a cold
  # cache would otherwise freeze the LiveView, Close included.
  defp start_fetch(socket, stub) do
    config = Map.get_lazy(socket.assigns, :metadata_config, &Metadata.default_relay_config/0)
    scope = socket.assigns.current_scope

    socket
    |> assign(:person_stub, stub)
    |> assign(:selected_person, nil)
    |> assign(:person_titles, [])
    |> assign(:person_error, nil)
    |> assign(:person_loading, true)
    |> assign(:person_status_stale, false)
    |> start_async(:load_person, fn -> fetch_and_enrich(config, stub.id, scope) end)
  end

  defp fetch_and_enrich(config, tmdb_id, scope) do
    with {:ok, %Person{} = person} <- People.fetch_person_cached(config, tmdb_id) do
      {:ok, {person, enrich_titles(person, scope)}}
    end
  end

  defp fail(socket, reason) do
    Logger.warning("Person lookup failed: #{inspect(reason)}")

    socket
    |> assign(:person_loading, false)
    |> assign(:person_error, reason)
  end

  defp parse_id(id) when is_integer(id) and id > 0, do: {:ok, id}

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_id(_), do: :error

  defp blank_to_nil(value) when is_binary(value) and value != "", do: value
  defp blank_to_nil(_), do: nil
end
