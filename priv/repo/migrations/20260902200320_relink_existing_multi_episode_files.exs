defmodule Mydia.Repo.Migrations.RelinkExistingMultiEpisodeFiles do
  use Ecto.Migration

  @moduledoc """
  Adds the episode links that were dropped before multi-episode files were
  supported.

  The previous migration backfills `media_file_episodes` one row per existing
  `media_files.episode_id`, which reproduces the old behaviour exactly: a
  `S01E09E10` file still claims only episode 9. This pass re-reads those
  filenames and adds the episodes that were discarded.

  It cannot be left to a re-scan: `Library.match_files_to_episodes/1` only
  considers files with `episode_id IS NULL`, and these already have one.
  """

  def up do
    # Parsing lives in Mydia.Library.MultiEpisodeRelink so it can be tested
    # like ordinary code rather than only through a migration.
    {:ok, _} = Mydia.Library.MultiEpisodeRelink.run()
  end

  def down do
    # The links are additive and harmless; dropping the join table in the
    # previous migration's `down` removes them.
    :ok
  end
end
