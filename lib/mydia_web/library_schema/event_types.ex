defmodule MydiaWeb.LibrarySchema.EventTypes do
  @moduledoc """
  Types for the events feed.

  `resourceType` and `resourceId` stay scalars because they outlive what they
  point at: a `media_item.removed` event names a row that no longer exists. A
  `resource` union can be added beside them later, and a typed payload beside
  `data`.
  """

  use Absinthe.Schema.Notation

  @desc "Arbitrary JSON, returned as stored"
  scalar :json, name: "JSON" do
    serialize(& &1)
    # Output only: no argument takes JSON.
    parse(fn _input -> :error end)
  end

  @desc "How serious an event is"
  enum :severity do
    value(:info, description: "Routine")
    value(:warning, description: "Worth a look")
    value(:error, description: "Something failed")
  end

  @desc "Something that happened in the library"
  object :event do
    field :id, non_null(:id)
    field :type, non_null(:string)
    field :occurred_at, non_null(:datetime), description: "When Mydia recorded it, to the second"
    field :severity, non_null(:severity)
    field :resource_type, :string
    field :resource_id, :id

    field :data, non_null(:json),
      description: "Type-specific details. Keys may change during beta."
  end

  @desc "One event in a page"
  object :event_edge do
    field :node, non_null(:event)
    field :cursor, non_null(:string)
  end

  @desc "A page of events"
  object :event_connection do
    field :edges, non_null(list_of(non_null(:event_edge)))
    field :page_info, non_null(:page_info)
  end
end
