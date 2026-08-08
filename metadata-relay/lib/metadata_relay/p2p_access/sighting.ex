defmodule MetadataRelay.P2pAccess.Sighting do
  @moduledoc """
  A p2p endpoint the relay has asked us about.

  Written only by the periodic flush in `MetadataRelay.P2pAccess.Store`.
  Never read or written on the authorization hot path.
  """

  use Ecto.Schema

  @primary_key {:endpoint_id, :string, autogenerate: false}

  schema "p2p_endpoint_sightings" do
    field(:first_seen, :utc_datetime)
    field(:last_seen, :utc_datetime)
    field(:conn_count, :integer, default: 0)
  end
end
