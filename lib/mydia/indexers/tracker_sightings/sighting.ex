defmodule Mydia.Indexers.TrackerSightings.Sighting do
  @moduledoc """
  One tracker seen in search results: the tracker-level terms it last
  reported (privacy, minimum ratio, minimum seed time in seconds) and when.
  Volume factors are per release and not kept. One row per `tracker_key`.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}

  @type t :: %__MODULE__{
          id: binary() | nil,
          tracker: String.t() | nil,
          tracker_key: String.t() | nil,
          private: boolean() | nil,
          minimum_ratio: float() | nil,
          minimum_seed_time: non_neg_integer() | nil,
          last_seen_at: DateTime.t() | nil
        }

  schema "tracker_sightings" do
    field :tracker, :string
    field :tracker_key, :string
    field :private, :boolean
    field :minimum_ratio, :float
    field :minimum_seed_time, :integer
    field :last_seen_at, :utc_datetime
  end
end
