defmodule Mydia.Repo.Migrations.ReplaceAudioLanguagesWithDownloadAudioLanguage do
  use Ecto.Migration

  import Mydia.Repo.Migrations.Helpers

  # A show's download audio override becomes one choice, "original" or a
  # language code, instead of an ordered list, and is named for what it governs
  # so it cannot be mistaken for the playback preference. The first entry of
  # the old list is the choice that list expressed. {:array, :text} is stored as
  # a JSON array on SQLite and as text[] on PostgreSQL, hence the two backfills.
  def up do
    alter table(:media_items) do
      add :download_audio_language, :text
    end

    flush()

    if postgres?() do
      execute("""
      UPDATE media_items SET download_audio_language = audio_languages[1]
      WHERE audio_languages IS NOT NULL
      """)
    else
      execute("""
      UPDATE media_items SET download_audio_language = json_extract(audio_languages, '$[0]')
      WHERE audio_languages IS NOT NULL
      """)
    end

    alter table(:media_items) do
      remove :audio_languages
    end
  end

  def down do
    alter table(:media_items) do
      add :audio_languages, {:array, :text}
    end

    flush()

    if postgres?() do
      execute("""
      UPDATE media_items SET audio_languages = ARRAY[download_audio_language]
      WHERE download_audio_language IS NOT NULL
      """)
    else
      execute("""
      UPDATE media_items SET audio_languages = json_array(download_audio_language)
      WHERE download_audio_language IS NOT NULL
      """)
    end

    alter table(:media_items) do
      remove :download_audio_language
    end
  end
end
