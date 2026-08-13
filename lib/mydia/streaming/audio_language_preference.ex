defmodule Mydia.Streaming.AudioLanguagePreference do
  @moduledoc """
  One viewer's audio language choice for one show or film.

  Written when someone picks a track in the player's audio selector, and read
  back on every later playback of the same item, so choosing English on
  episode 3 holds for episode 4. That stickiness is the thing Plex, Jellyfin
  and Infuse all leave open: all three treat a manual pick as a per-playback
  override and make the viewer repeat it every episode.

  Scoped to the media item, never the episode. A per-episode row would
  reproduce exactly the behaviour this exists to remove.

  Deliberately not folded into `Mydia.Accounts.UserPreference`'s map column,
  which is where a flexible per-user setting would otherwise live: this grows
  one entry per show watched, and a map column would have to be
  read-modified-written, so two devices setting a language at once could lose
  one of the writes. A row with a unique index upserts atomically instead.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          id: binary(),
          language: String.t(),
          user_id: binary(),
          media_item_id: binary(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "audio_language_preferences" do
    field :language, :string

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
    |> cast(attrs, [:language])
    |> validate_required([:language])
    # Long enough for "pt-BR", short enough to reject anything that is not a
    # language tag. The value reaches ffmpeg's -map selection and mpv's alang,
    # so it is bounded here rather than trusted from the client.
    |> validate_length(:language, min: 2, max: 16)
    |> unique_constraint([:user_id, :media_item_id])
  end
end
