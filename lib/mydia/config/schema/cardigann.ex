defmodule Mydia.Config.Schema.Cardigann do
  @moduledoc """
  The `cardigann` section of `Mydia.Config.Schema`: which engine runs Cardigann
  definitions, the Elixir one or Prowlarr's compiled to wasm. Editable on the
  Indexers tab; `CARDIGANN_ENGINE` locks it.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :engine, Ecto.Enum, values: [:builtin, :prowlarr], default: :builtin
  end

  @type t :: %__MODULE__{}

  def changeset(schema, attrs), do: cast(schema, attrs, [:engine])
end
