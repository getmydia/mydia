defmodule MydiaWeb.LibrarySchema.Resolvers.Events do
  @moduledoc """
  Resolves `events` over `Mydia.LibraryApi.EventFeed`.

  The feed is best-effort (see EventFeed's moduledoc): `mediaItemChanges` and
  `downloads` stay the source of truth.
  """

  alias Mydia.LibraryApi.Cursor
  alias Mydia.LibraryApi.EventFeed
  alias MydiaWeb.LibrarySchema.Paging

  @default_first 100
  @max_first 200

  @spec events(any(), map(), Absinthe.Resolution.t()) :: {:ok, map()} | {:error, map()}
  def events(_parent, args, _info) do
    with {:ok, first} <- Paging.page_size(Map.get(args, :first), @default_first, @max_first),
         {:ok, after_cursor} <- Paging.decode_cursor(Map.get(args, :after)),
         {:ok, rows} <- feed(first, after_cursor, Map.get(args, :types)) do
      {page, rest} = Enum.split(rows, first)
      {:ok, connection(page, rest != [], Map.get(args, :after))}
    end
  end

  # One extra row decides hasNextPage without a second count query.
  defp feed(first, after_cursor, types) do
    case EventFeed.list(limit: first + 1, after: after_cursor, types: types) do
      {:ok, rows} ->
        {:ok, rows}

      {:error, {:unknown_types, unknown}} ->
        {:error,
         %{
           message: "Unknown event types: #{Enum.join(unknown, ", ")}",
           extensions: %{code: "INVALID_INPUT"}
         }}

      {:error, :empty_types} ->
        {:error,
         %{
           message:
             "types must name at least one event type, or be omitted entirely to receive every published type",
           extensions: %{code: "INVALID_INPUT"}
         }}
    end
  end

  # An empty page repeats the cursor the client sent, so a poller that always
  # passes endCursor back never restarts from the beginning.
  defp connection([], _has_next, after_cursor),
    do: %{edges: [], page_info: %{has_next_page: false, end_cursor: after_cursor}}

  defp connection(page, has_next, _after_cursor) do
    last = List.last(page)

    %{
      edges:
        Enum.map(page, &%{node: event_map(&1), cursor: Cursor.encode(&1.inserted_at, &1.id)}),
      page_info: %{has_next_page: has_next, end_cursor: Cursor.encode(last.inserted_at, last.id)}
    }
  end

  defp event_map(event) do
    %{
      id: event.id,
      type: event.type,
      occurred_at: event.inserted_at,
      severity: event.severity,
      resource_type: event.resource_type,
      resource_id: event.resource_id,
      data: event.metadata || %{}
    }
  end
end
