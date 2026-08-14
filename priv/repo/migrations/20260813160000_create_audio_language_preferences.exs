defmodule Mydia.Repo.Migrations.CreateAudioLanguagePreferences do
  use Ecto.Migration

  def change do
    # Keyed on the media item rather than the episode, deliberately. Picking
    # English once on episode 3 is meant to hold for the rest of the series,
    # which is the gap Plex, Jellyfin and Infuse all leave open. A per-episode
    # row would make the viewer re-pick every episode, which is the behaviour
    # this exists to remove. Movies key on the same column, so a film gets one
    # row of its own.
    create table(:audio_language_preferences, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :media_item_id, references(:media_items, type: :binary_id, on_delete: :delete_all),
        null: false

      # A single code, not a list. This records one deliberate choice a person
      # made about one show; the ordered fallback list is the operator's
      # setting and stays in streaming.audio_language.
      add :language, :text, null: false

      timestamps(type: :utc_datetime)
    end

    # One preference per viewer per show, which is also what lets the write be
    # an atomic upsert. Two devices setting a language at once then resolve to
    # a last-writer-wins row rather than racing a read-modify-write.
    create unique_index(:audio_language_preferences, [:user_id, :media_item_id])
  end
end
