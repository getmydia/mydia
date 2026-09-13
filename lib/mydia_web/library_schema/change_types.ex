defmodule MydiaWeb.LibrarySchema.ChangeTypes do
  @moduledoc """
  Types for `mediaItemChanges`, the revision-paged change feed.

  A change is either a live item or a tombstone. It carries `mediaItemId` even
  when `mediaItem` is null, so a consumer can act on a deletion without keeping
  the item's previous payload around. `changedAt` is the marker's timestamp: for
  a live item it equals `mediaItem.updatedAt`, and a tombstone has no other place
  to report when the deletion happened.
  """

  use Absinthe.Schema.Notation

  @desc "One media item change: a live item or a tombstone for a deleted one"
  object :media_item_change do
    field :media_item_id, non_null(:id)

    field :deleted, non_null(:boolean),
      description: "True when the item was deleted; mediaItem is then null"

    field :changed_at, non_null(:datetime),
      description: "When this revision was recorded; equals mediaItem.updatedAt when live"

    field :media_item, :media_item
  end

  @desc "One change in a page"
  object :media_item_change_edge do
    field :node, non_null(:media_item_change)

    field :cursor, non_null(:string),
      description: "Opaque; pass the last edge's cursor as `after` for the next page"
  end

  @desc "A page of media item changes, oldest revision first"
  object :media_item_change_connection do
    field :edges, non_null(list_of(non_null(:media_item_change_edge)))
    field :page_info, non_null(:page_info)
  end
end
