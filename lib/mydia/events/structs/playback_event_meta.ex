defmodule Mydia.Events.Structs.PlaybackEventMeta do
  @moduledoc """
  Metadata for `playback.*` events (U1).

  Carries the user-scoped playback context a plugin needs to react to a
  watch: which content moved, how far, whether it completed, and where the
  write came from (`origin`). The user itself rides in the event envelope's
  `actor_id`, not here.

  `origin` is one of `"player"` (a real client write), `"sync:<provider>"`
  (a media-server import), or `"plugin:<slug>"` (a plugin write-back).
  The dispatcher uses it to suppress delivery of an event back to the plugin
  that caused it (R14).
  """

  @derive Jason.Encoder

  defstruct [
    :media_item_id,
    :episode_id,
    :position_seconds,
    :duration_seconds,
    :completion_percentage,
    :watched,
    :origin
  ]

  @type t :: %__MODULE__{
          media_item_id: String.t() | nil,
          episode_id: String.t() | nil,
          position_seconds: integer() | nil,
          duration_seconds: integer() | nil,
          completion_percentage: float() | nil,
          watched: boolean() | nil,
          origin: String.t() | nil
        }

  @known_keys %{
    "media_item_id" => :media_item_id,
    "episode_id" => :episode_id,
    "position_seconds" => :position_seconds,
    "duration_seconds" => :duration_seconds,
    "completion_percentage" => :completion_percentage,
    "watched" => :watched,
    "origin" => :origin
  }

  @doc """
  Converts a string-key map (an event's stored `metadata`) to a struct.

  Unknown keys are silently ignored.

  ## Examples

      iex> PlaybackEventMeta.from_map(%{"origin" => "player", "watched" => true})
      %PlaybackEventMeta{origin: "player", watched: true}
  """
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    attrs =
      for {k, v} <- map,
          atom_key = Map.get(@known_keys, to_string(k)),
          into: %{},
          do: {atom_key, v}

    struct(__MODULE__, attrs)
  end
end
