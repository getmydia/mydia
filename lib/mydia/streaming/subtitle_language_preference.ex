defmodule Mydia.Streaming.SubtitleLanguagePreference do
  @moduledoc """
  One viewer's subtitle choice for one show or film.

  Written when someone picks a track (or picks Off) in the player's subtitle
  sheet, and read back on every later playback of the same item, so a choice
  made on episode 3 holds for episode 4.

  Stores a descriptor rather than a track id on purpose. A subtitle track id
  is an ffprobe stream index, a sidecar UUID, or the player's own synthetic
  `mk_<n>`, none of which mean anything on the next episode's file. The
  language plus the disposition flags do.

  `mode: :off` is a stored choice, not an absent one. The distinction matters:
  a missing row lets the operator default select a track, while an explicit
  off must beat it.

  Mirrors `Mydia.Streaming.AudioLanguagePreference`, including its reason for
  being a row with a unique index rather than an entry in a map column.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @modes [:off, :track]

  @type t :: %__MODULE__{
          id: binary(),
          mode: :off | :track,
          language: String.t() | nil,
          forced: boolean(),
          hearing_impaired: boolean(),
          track_title: String.t() | nil,
          user_id: binary(),
          media_item_id: binary(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "subtitle_language_preferences" do
    field :mode, Ecto.Enum, values: @modes
    field :language, :string
    field :forced, :boolean, default: false
    field :hearing_impaired, :boolean, default: false
    field :track_title, :string

    belongs_to :user, Mydia.Accounts.User
    belongs_to :media_item, Mydia.Media.MediaItem

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset for a preference.

  `user_id` and `media_item_id` are set programmatically by the context rather
  than cast, so a client cannot write a preference onto another account.
  """
  def changeset(preference, attrs) do
    preference
    |> cast(attrs, [:mode, :language, :forced, :hearing_impaired, :track_title])
    |> validate_required([:mode])
    |> validate_inclusion(:mode, @modes)
    |> validate_language_matches_mode()
    # Long enough for "pt-BR", short enough to reject anything that is not a
    # language tag. Bounded here rather than trusted from the client.
    |> validate_length(:language, min: 2, max: 16)
    # A title is a display string from a container; bounded so a malformed or
    # hostile one cannot grow the row without limit.
    |> validate_length(:track_title, max: 255)
    |> unique_constraint([:user_id, :media_item_id])
  end

  # The two fields are not independent: a track choice without a language
  # cannot be matched against anything, and an "off" carrying a language is
  # two contradictory instructions in one row.
  defp validate_language_matches_mode(changeset) do
    case get_field(changeset, :mode) do
      :track -> validate_required(changeset, [:language])
      :off -> reject_language(changeset)
      _ -> changeset
    end
  end

  defp reject_language(changeset) do
    case get_field(changeset, :language) do
      nil -> changeset
      _ -> add_error(changeset, :language, "must be blank when subtitles are off")
    end
  end
end
