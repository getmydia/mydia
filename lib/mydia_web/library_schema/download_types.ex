defmodule MydiaWeb.LibrarySchema.DownloadTypes do
  @moduledoc "Types for the download queue and history."

  use Absinthe.Schema.Notation

  @desc "The download client a row belongs to"
  object :download_client do
    field :name, non_null(:string)

    field :state, non_null(:client_config_state),
      description: "Whether this client is still configured, disabled, or gone"
  end

  @desc "The indexer a row was grabbed from"
  object :indexer do
    field :name, non_null(:string)
  end

  @desc "A download, with live status from its client"
  object :download do
    field :id, non_null(:id)
    field :title, non_null(:string)
    field :status, non_null(:download_status)
    field :progress, :float, description: "Percentage, 0 to 100"
    field :size_bytes, :float, description: "Float because GraphQL Int is 32-bit"
    field :downloaded_bytes, :float
    field :eta_seconds, :integer

    field :download_client, :download_client,
      description: "Null for a grab that has not reached a client yet"

    field :indexer, :indexer
    field :error_message, :string
    field :import_failure_reason, :string
    field :import_failed_at, :datetime
    field :media_item, :media_item
    field :episode, :episode
    field :added_at, non_null(:datetime)
  end
end
