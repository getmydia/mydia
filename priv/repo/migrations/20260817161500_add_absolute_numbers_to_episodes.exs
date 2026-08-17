defmodule Mydia.Repo.Migrations.AddAbsoluteNumbersToEpisodes do
  use Ecto.Migration

  def change do
    alter table(:episodes) do
      # TVDB returns absoluteNumber on every episode and Mydia discarded it.
      # It is the join key that makes a season reordering lossless: the same
      # episode carries the same absolute number in official, DVD and absolute
      # orderings.
      add :absolute_number, :integer

      # The provider's own episode id. Season and episode number are not a
      # stable identity, because they are exactly what a reordering changes.
      add :provider_episode_id, :text
    end

    create index(:episodes, [:media_item_id, :absolute_number])

    # Partial on not-null so the backfill can proceed one show at a time
    # without existing null rows colliding with each other.
    create unique_index(:episodes, [:media_item_id, :provider_episode_id],
             where: "provider_episode_id IS NOT NULL",
             name: :episodes_media_item_id_provider_episode_id_index
           )
  end
end
