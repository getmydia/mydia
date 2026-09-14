defmodule Mydia.Repo.Migrations.MakeMediaFilesTrashedAtIndexPartial do
  @moduledoc """
  Narrows `media_files_trashed_at_index` to the rows that are actually trashed.

  Nearly every media file is untrashed, so an index entry for `trashed_at IS
  NULL` covers almost the whole table and is never a good way in. SQLite cannot
  tell: these installs have no `sqlite_stat1`, so its planner assumes the
  predicate is selective. It drove the `Episode.media_files` preload from this
  index and then probed `media_file_episodes` once per episode id for every
  file, which took 1.8 seconds on a 3,773 episode library and made `/tv` take
  over three seconds.

  The predicate is spelled `NOT (trashed_at IS NULL)` rather than the more usual
  `trashed_at IS NOT NULL` on purpose. That is the exact text Ecto emits for
  `not is_nil(f.trashed_at)`, and SQLite matches a partial index only against a
  query term of the same shape (or a comparison such as `trashed_at <= ?`,
  which implies it). Written the usual way, the trash page and its counts fall
  back to a full table scan. PostgreSQL normalises both spellings to the same
  predicate.
  """
  use Ecto.Migration

  def up do
    drop_if_exists index(:media_files, [:trashed_at])
    create index(:media_files, [:trashed_at], where: "NOT (trashed_at IS NULL)")
  end

  def down do
    drop_if_exists index(:media_files, [:trashed_at])
    create index(:media_files, [:trashed_at])
  end
end
