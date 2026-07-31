defmodule MetadataRelay.P2pAccess.Block do
  @moduledoc """
  An endpoint that is denied relay access.

  Written synchronously on admin action, and loaded into ETS at boot.
  """

  use Ecto.Schema

  @primary_key {:endpoint_id, :string, autogenerate: false}

  schema "p2p_blocked_endpoints" do
    field(:reason, :string)
    field(:blocked_at, :utc_datetime)
  end
end
