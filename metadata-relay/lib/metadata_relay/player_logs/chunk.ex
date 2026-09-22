defmodule MetadataRelay.PlayerLogs.Chunk do
  @moduledoc """
  One uploaded batch: a gzipped NDJSON file under the logs directory, and what
  is needed to find it without opening it.

  `bytes` is the compressed size on disk, which the disk cap sums. `sessions`
  is JSON: one entry per session ID in the batch, with its first and last `t`
  and a line count, which the dashboard's device page adds up.
  """

  use Ecto.Schema

  schema "player_log_chunks" do
    field(:device_id, :string)
    field(:kind, :string)
    field(:path, :string)
    field(:first_t, :integer)
    field(:last_t, :integer)
    field(:line_count, :integer)
    field(:bytes, :integer)
    field(:sessions, :string)
    field(:report_code, :string)

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @type t :: %__MODULE__{}
end
