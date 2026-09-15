defmodule Mydia.Perf.Rollup do
  @moduledoc """
  One hour of one metric and tag set, from one boot. Written by
  `Mydia.Perf.Flusher`, read by `Mydia.Perf.report/1`.

  `buckets` is JSON text encoded by the flusher, not a `:map` field: the column
  is `text` on both adapters, and a `:map` field would send `jsonb` to
  PostgreSQL.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "perf_rollups" do
    field :hour, :utc_datetime
    field :boot_id, :string
    field :metric, :string
    field :tags, :string
    field :count, :integer
    field :sum_us, :integer
    field :buckets, :string

    timestamps(type: :utc_datetime)
  end

  @doc "The start of the UTC hour containing `datetime`, at second precision."
  @spec hour_of(DateTime.t()) :: DateTime.t()
  def hour_of(%DateTime{} = datetime) do
    %{DateTime.truncate(datetime, :second) | minute: 0, second: 0}
  end
end
