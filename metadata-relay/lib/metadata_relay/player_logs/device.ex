defmodule MetadataRelay.PlayerLogs.Device do
  @moduledoc """
  A player install that has uploaded logs, keyed by the random
  `diagnostics.device_id` the player creates on its first upload.

  `bytes_today` counts decompressed bytes against the daily quota, for the UTC
  date in `bytes_day`.
  """

  use Ecto.Schema

  @primary_key {:device_id, :string, autogenerate: false}

  schema "player_log_devices" do
    field(:name, :string)
    field(:platform, :string)
    field(:os_version, :string)
    field(:app_version, :string)
    field(:first_seen_at, :utc_datetime)
    field(:last_seen_at, :utc_datetime)
    field(:bytes_today, :integer, default: 0)
    field(:bytes_day, :date)
  end

  @type t :: %__MODULE__{}
end
