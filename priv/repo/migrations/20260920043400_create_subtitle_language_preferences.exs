defmodule Mydia.Repo.Migrations.CreateSubtitleLanguagePreferences do
  use Ecto.Migration

  def change do
    # Keyed on the media item, not the episode, for the same reason
    # audio_language_preferences is: picking a subtitle once on episode 3 is
    # meant to hold for the rest of the series. A per-episode row would
    # reproduce the behaviour this exists to remove. Movies key on the same
    # column and get one row of their own.
    create table(:subtitle_language_preferences, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :media_item_id, references(:media_items, type: :binary_id, on_delete: :delete_all),
        null: false

      # "off" or "track". An explicit off is a real choice and has to be
      # storable: without it, turning subtitles off would read as "never
      # chose", and the operator default would switch them back on next
      # episode.
      add :mode, :text, null: false

      # Null exactly when mode is "off". A track id would be useless here:
      # ids are an ffprobe stream index or a sidecar UUID and mean nothing on
      # the next episode's file.
      add :language, :text

      add :forced, :boolean, null: false, default: false
      add :hearing_impaired, :boolean, null: false, default: false

      # A tiebreak only, never a requirement. Two tracks can share a language
      # and both flags; a release names them consistently across a season, so
      # the remembered title separates them.
      add :track_title, :text

      timestamps(type: :utc_datetime)
    end

    # One preference per viewer per item, which is what lets the write be an
    # atomic upsert. Two devices choosing at once settle on one row rather
    # than racing a read-modify-write.
    create unique_index(:subtitle_language_preferences, [:user_id, :media_item_id])
  end
end
