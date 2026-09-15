defmodule Mydia.Repo.Migrations.AddAudioLanguagesToMediaItems do
  use Ecto.Migration

  # A show's own audio language preference. NULL means "inherit
  # streaming.audio_language". {:array, :text} rather than {:array, :string},
  # which is varchar(255)[] on PostgreSQL and fails
  # no_varchar_columns_test.exs.
  def change do
    alter table(:media_items) do
      add :audio_languages, {:array, :text}
    end
  end
end
