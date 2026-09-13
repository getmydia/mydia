defmodule MydiaWeb.LibrarySchema.Resolvers.MediaItemChanges do
  @moduledoc """
  Resolves `mediaItemChanges` over `Mydia.LibraryApi.RevisionFeed`.

  The feed is the latest state of every media item, ordered by a
  database-generated revision and resumed strictly after an opaque
  `Mydia.LibraryApi.RevisionCursor`. A page is fetched one row longer than asked
  so `hasNextPage` needs no second query, and every cursor comes from the
  boundary marker's revision rather than a timestamp: two items written in the
  same microsecond still page deterministically, and an item rewritten while the
  consumer reads is never skipped or repeated.

  Hydration adds one query per page, not per item, and a live marker whose item
  cannot be read back is reported as a tombstone -- the item is gone, so saying
  so is better than dropping the edge and losing the change.
  """

  alias Mydia.LibraryApi.MediaItemRevision
  alias Mydia.LibraryApi.RevisionCursor
  alias Mydia.LibraryApi.RevisionFeed
  alias Mydia.Media
  alias MydiaWeb.LibrarySchema.MediaItemView
  alias MydiaWeb.LibrarySchema.Paging

  @default_first 50
  @max_first 200

  @spec media_item_changes(any(), map(), Absinthe.Resolution.t()) ::
          {:ok, map()} | {:error, map()}
  def media_item_changes(_parent, args, _info), do: resolve(args, [])

  @doc false
  @spec resolve(map(), keyword()) :: {:ok, map()} | {:error, map()}
  def resolve(args, opts) do
    load_items = Keyword.get(opts, :load_items, &load_items/1)

    with {:ok, first} <- Paging.page_size(Map.get(args, :first), @default_first, @max_first),
         {:ok, after_revision} <- decode_revision(Map.get(args, :after)) do
      rows = RevisionFeed.list(limit: first + 1, after: after_revision)
      {page, rest} = Enum.split(rows, first)
      live_ids = for marker <- page, not marker.deleted, do: marker.media_item_id

      {:ok, connection(page, load_items.(live_ids), rest != [], Map.get(args, :after))}
    end
  end

  # Hydration is one batch query for the page's live ids.
  defp load_items([]), do: %{}

  defp load_items(ids) do
    found = Media.list_media_items(ids: ids, preload: MediaItemView.preloads())
    Map.new(found, &{&1.id, &1})
  end

  defp decode_revision(nil), do: {:ok, nil}

  defp decode_revision(cursor) do
    case RevisionCursor.decode(cursor) do
      {:ok, revision} ->
        {:ok, revision}

      :error ->
        {:error, %{message: "Invalid cursor", extensions: %{code: "INVALID_INPUT"}}}
    end
  end

  # An empty page repeats the cursor the client sent, so a poller that always
  # passes endCursor back never restarts from the beginning.
  defp connection([], _items, _has_next, after_cursor),
    do: %{edges: [], page_info: %{has_next_page: false, end_cursor: after_cursor}}

  defp connection(page, items, has_next, _after_cursor) do
    last = List.last(page)

    %{
      edges:
        Enum.map(page, fn marker ->
          %{node: change_node(marker, items), cursor: RevisionCursor.encode(marker.revision)}
        end),
      page_info: %{has_next_page: has_next, end_cursor: RevisionCursor.encode(last.revision)}
    }
  end

  defp change_node(%MediaItemRevision{deleted: true} = marker, _items), do: tombstone(marker)

  defp change_node(%MediaItemRevision{} = marker, items) do
    case Map.fetch(items, marker.media_item_id) do
      {:ok, item} -> live_change(marker, item)
      :error -> tombstone(marker)
    end
  end

  defp live_change(marker, item) do
    %{
      media_item_id: marker.media_item_id,
      deleted: false,
      changed_at: marker.changed_at,
      media_item: MediaItemView.item_map(item, marker.changed_at)
    }
  end

  defp tombstone(marker) do
    %{
      media_item_id: marker.media_item_id,
      deleted: true,
      changed_at: marker.changed_at,
      media_item: nil
    }
  end
end
