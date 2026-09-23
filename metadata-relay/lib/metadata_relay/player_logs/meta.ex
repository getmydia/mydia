defmodule MetadataRelay.PlayerLogs.Meta do
  @moduledoc """
  The first line of a `POST /player-logs` body, validated by
  `MetadataRelay.PlayerLogs.Ingest`. Every string is already length-capped.
  """

  @enforce_keys [:device_id, :kind]
  defstruct [
    :device_id,
    :kind,
    :report,
    :device_name,
    :platform,
    :os_version,
    :app_version,
    :build,
    :note
  ]

  @type t :: %__MODULE__{
          device_id: String.t(),
          kind: String.t(),
          report: String.t() | nil,
          device_name: String.t() | nil,
          platform: String.t() | nil,
          os_version: String.t() | nil,
          app_version: String.t() | nil,
          build: String.t() | nil,
          note: String.t() | nil
        }
end
