defmodule Mydia.Repo.Migrations.DropUnusedAbsoluteNumberIndex do
  use Ecto.Migration

  # `add_absolute_numbers_to_episodes` created this index calling
  # absolute_number "the join key that makes a season reordering lossless".
  # It did not turn out that way: `Mydia.Media.SeasonOrder.remap/3` keys on
  # provider_episode_id, which is the identity a reordering preserves, and
  # nothing anywhere reads absolute_number back. The column is still written
  # from TVDB and is worth keeping, but the index supports no query and costs
  # a write on every episode insert and update on a high-row-count table --
  # while indexing a column that is NULL on every row written before it
  # existed.
  #
  # Recreate it (scoped, if it is ever this shape again) when a query actually
  # needs it.
  def change do
    drop index(:episodes, [:media_item_id, :absolute_number])
  end
end
