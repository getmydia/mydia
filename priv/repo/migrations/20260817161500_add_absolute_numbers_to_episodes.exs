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

    # Partial on not-null as a size optimization, not a correctness
    # requirement: a plain unique index already permits unlimited NULLs per
    # media_item_id, since SQL treats NULL as distinct from NULL. episodes is
    # a high-row-count table and most rows will hold NULL provider_episode_id
    # until the backfill completes, so scoping the index to non-null rows
    # keeps it from indexing rows it can never usefully constrain.
    create unique_index(:episodes, [:media_item_id, :provider_episode_id],
             where: "provider_episode_id IS NOT NULL",
             name: :episodes_media_item_id_provider_episode_id_index
           )
  end
end
