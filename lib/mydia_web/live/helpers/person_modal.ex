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

  The fetch runs under `start_async(:load_person, ...)`, so the host owns the
  matching `handle_async(:load_person, result, socket)` clause and hands the
  result to `handle_result/2`. The host must have a `:metadata_config` assign
  and a `:current_scope`.
  """

  require Logger

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [start_async: 3, cancel_async: 2]

  alias Mydia.Accounts.Scope
  alias Mydia.Media
  alias Mydia.Media.RemoteFilter
  alias Mydia.Metadata
  alias Mydia.Metadata.Structs.{Person, PersonCredit, SearchResult}
  alias MydiaWeb.Live.Helpers.{MediaAddHelpers, MediaRequestHelpers}

  @doc """
  Assigns every person assign to its empty value. Call from `mount/3`.
  """
  def init(socket) do
    socket
    |> assign(:selected_person, nil)
    |> assign(:person_stub, nil)
    |> assign(:person_loading, false)
    |> assign(:person_error, nil)
    |> assign(:person_titles, [])
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

  Returns the socket, not a `{:noreply, _}` tuple, so a host can pipe further.
  """
  def handle_result(%{assigns: %{person_stub: nil}} = socket, _result), do: socket

  def handle_result(
        %{assigns: %{person_stub: %{id: stub_id}}} = socket,
        {:ok, {:ok, %Person{tmdb_id: id}}}
      )
      when id != stub_id,
      do: socket

  def handle_result(socket, {:ok, {:ok, %Person{} = person}}) do
    titles = enrich_titles(person, socket.assigns.current_scope)

    socket
    |> assign(:selected_person, person)
    |> assign(:person_titles, titles)
    |> assign(:person_loading, false)
    |> assign(:person_error, nil)
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
  The person's titles, for hosts that resolve a `show_details` click against a
  selectable list.
  """
  def titles(socket), do: socket.assigns.person_titles

  @doc """
  The person's credits as `SearchResult`s the viewer may see, movies first, with
  library and request status.

  Movie and TV ids are looked up separately: a movie and a show can share a TMDB
  id, and the status map is keyed by media type.
  """
  @spec enrich_titles(Person.t(), Scope.t()) :: [SearchResult.t()]
  def enrich_titles(%Person{} = person, %Scope{} = scope) do
    results =
      (person.movie_credits ++ person.tv_credits)
      |> Enum.map(&PersonCredit.to_search_result/1)
      |> RemoteFilter.filter(scope)

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

  defp start_fetch(socket, stub) do
    config = socket.assigns.metadata_config

    socket
    |> assign(:person_stub, stub)
    |> assign(:selected_person, nil)
    |> assign(:person_titles, [])
    |> assign(:person_error, nil)
    |> assign(:person_loading, true)
    |> start_async(:load_person, fn -> Metadata.fetch_person_cached(config, stub.id) end)
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
