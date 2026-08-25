defmodule Mydia.Repo.Migrations.AddContentRatingAgeToMediaItems do
  use Ecto.Migration

  @moduledoc """
  Promotes the content rating out of the metadata JSON blob as a normalized age.

  `metadata` is a `:text` column holding JSON, so filtering on the rating
  inside it needs adapter-specific JSON extraction. A plain integer column is
  what lets `Mydia.Media.Restrictions` express a maximum age limit as portable
  SQL on both SQLite and PostgreSQL.

  Nullable on purpose. NULL means unrated, which an active age limit hides.
  """

  def change do
    alter table(:media_items) do
      add :content_rating_age, :integer
    end

    create index(:media_items, [:content_rating_age])
  end
end
