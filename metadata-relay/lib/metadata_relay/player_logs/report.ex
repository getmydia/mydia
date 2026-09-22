defmodule MetadataRelay.PlayerLogs.Report do
  @moduledoc """
  Logs a user sent on purpose from the player's Diagnostics screen, under a
  code they can quote in an issue.
  """

  use Ecto.Schema

  @primary_key {:code, :string, autogenerate: false}

  schema "player_log_reports" do
    field(:device_id, :string)
    field(:note, :string)

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @type t :: %__MODULE__{}
end
