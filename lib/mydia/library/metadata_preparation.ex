defmodule Mydia.Library.MetadataPreparation do
  @moduledoc """
  Provider data fetched before an import-candidate ownership transaction.

  The struct contains no durable side effect. `MetadataEnricher.persist/1`
  applies it while the caller owns the transaction that also creates files
  and deletes candidates.
  """

  @enforce_keys [:provider_id, :provider_type, :media_type, :operation, :episode_seasons]
  defstruct [
    :provider_id,
    :provider_type,
    :media_type,
    :operation,
    :media_item_id,
    :media_item_attrs,
    episode_seasons: []
  ]

  @type operation :: :create | :update | :stamp_source | :reuse

  @type t :: %__MODULE__{
          provider_id: String.t(),
          provider_type: :tmdb | :tvdb,
          media_type: :movie | :tv_show,
          operation: operation(),
          media_item_id: binary() | nil,
          media_item_attrs: map() | nil,
          episode_seasons: [struct()]
        }
end
