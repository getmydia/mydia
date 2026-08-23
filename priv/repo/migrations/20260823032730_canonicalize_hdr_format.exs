defmodule Mydia.Repo.Migrations.CanonicalizeHdrFormat do
  use Ecto.Migration

  @moduledoc """
  Moves media_files.hdr_format from free-text display strings to the canonical
  vocabulary in Mydia.Library.Hdr, and promotes the two Dolby Vision facts to
  their own columns.

  Both DV columns are left null here. The one-shot Mydia.Jobs.HdrBackfill worker
  re-probes every affected row and fills them from ffprobe directly, so reading
  them out of the stored StreamInfo JSON would be redundant work, and portable
  JSON extraction across SQLite and PostgreSQL is fragile for no gain.

  "Dolby Vision" maps to a provisional 'hdr10' rather than an honest NULL. That
  is deliberate: the backfill job selects on `hdr_format IS NOT NULL`, and that
  predicate is only complete if this migration never nulls a row it found.
  """

  def up do
    # :integer, not :string. See the no_varchar_columns_test gate.
    alter table(:media_files) do
      add :dolby_vision_profile, :integer
      add :dolby_vision_bl_compat_id, :integer
      # Backfill bookkeeping. Mydia.Jobs.HdrBackfill stamps this on every row
      # it has probed, whatever the outcome, so its pending set drains without
      # a sentinel value leaking into the GraphQL API. A later migration can
      # drop this column once every install has drained.
      add :hdr_backfilled_at, :utc_datetime
    end

    flush()

    # Plain UPDATE ... WHERE behaves identically on SQLite and PostgreSQL, so
    # no adapter branching is needed here.
    execute "UPDATE media_files SET hdr_format = 'hdr10_plus' WHERE hdr_format = 'HDR10+'"
    execute "UPDATE media_files SET hdr_format = 'hlg' WHERE hdr_format = 'HLG'"

    execute """
    UPDATE media_files SET hdr_format = 'hdr10'
    WHERE hdr_format IN ('HDR10', 'HDR', 'Dolby Vision')
    """

    # Anything unrecognised would fail to load through Ecto.Enum, so it is
    # cleared rather than left to raise at read time.
    execute """
    UPDATE media_files SET hdr_format = NULL
    WHERE hdr_format IS NOT NULL
      AND hdr_format NOT IN ('hdr10', 'hdr10_plus', 'hlg')
    """
  end

  def down do
    execute "UPDATE media_files SET hdr_format = 'HDR10+' WHERE hdr_format = 'hdr10_plus'"
    execute "UPDATE media_files SET hdr_format = 'HDR10' WHERE hdr_format = 'hdr10'"
    execute "UPDATE media_files SET hdr_format = 'HLG' WHERE hdr_format = 'hlg'"

    alter table(:media_files) do
      remove :dolby_vision_profile
      remove :dolby_vision_bl_compat_id
      remove :hdr_backfilled_at
    end
  end
end
