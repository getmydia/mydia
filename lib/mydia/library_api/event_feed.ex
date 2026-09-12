defmodule Mydia.LibraryApi.EventFeed do
  @moduledoc """
  A forward-only keyset feed over the existing `events` table.

  Oldest first, ordered by `(inserted_at, id)`, strictly after the cursor. The
  comparison is spelled out (`inserted_at > ts or (inserted_at == ts and id > id)`)
  so it runs on SQLite and PostgreSQL alike. The existing `inserted_at` index
  serves the range; ties within a second are few.

  Best-effort, and the API says so:

    * `Mydia.Events.Writer` drops events under overload and loses a batch whose
      insert fails, so the feed can have gaps. `mediaItems(updatedSince:)` and
      `downloads` stay the source of truth.
    * `inserted_at` is stamped in the caller's process before the event is
      flushed; the writer can block in Repo.insert_all/2 for up to the
      database's busy_timeout (30 seconds). Rows younger than the settle window
      (35 seconds) are withheld, which is longer than the write timeout, so an
      event written during a library scan still lands before the feed hands out
      a cursor past it.
    * The existing cleanup deletes events after 90 days. A cursor older than that
      resumes at the oldest remaining event.
  """

  import Ecto.Query

  alias Mydia.Events.Event
  alias Mydia.Plugins.Manifest
  alias Mydia.Repo

  @settle_seconds 35

  @doc """
  Lists events oldest first.

  Options: `:limit` (required), `:after` (an `{inserted_at, id}` pair from
  `Mydia.LibraryApi.Cursor.decode/1`), `:types` (defaults to the plugin event
  catalog; a type outside it is refused, and an empty list is refused too,
  rather than compiling to `WHERE type IN ()` and returning an empty feed
  forever), `:now` (the clock, for tests).
  """
  @spec list(keyword()) ::
          {:ok, [Event.t()]}
          | {:error, {:unknown_types, [String.t()]}}
          | {:error, :empty_types}
  def list(opts) do
    with {:ok, types} <- types(Keyword.get(opts, :types)) do
      settled =
        opts
        |> Keyword.get(:now, DateTime.utc_now())
        |> DateTime.add(-@settle_seconds, :second)
        |> DateTime.truncate(:second)

      events =
        Event
        |> where([e], e.type in ^types)
        |> where([e], e.inserted_at <= ^settled)
        |> after_cursor(Keyword.get(opts, :after))
        |> order_by([e], asc: e.inserted_at, asc: e.id)
        |> limit(^Keyword.fetch!(opts, :limit))
        |> Repo.all()

      {:ok, events}
    end
  end

  @doc "Seconds a new event is withheld before the feed returns it."
  @spec settle_seconds() :: pos_integer()
  def settle_seconds, do: @settle_seconds

  defp types(nil), do: {:ok, Manifest.event_catalog()}
  defp types([]), do: {:error, :empty_types}

  defp types(requested) do
    catalog = Manifest.event_catalog()

    case Enum.reject(requested, &(&1 in catalog)) do
      [] -> {:ok, requested}
      unknown -> {:error, {:unknown_types, unknown}}
    end
  end

  defp after_cursor(query, nil), do: query

  defp after_cursor(query, {inserted_at, id}) do
    where(
      query,
      [e],
      e.inserted_at > ^inserted_at or (e.inserted_at == ^inserted_at and e.id > ^id)
    )
  end
end
