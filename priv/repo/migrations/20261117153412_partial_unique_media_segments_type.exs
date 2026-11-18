defmodule Mydia.Repo.Migrations.PartialUniqueMediaSegmentsType do
  use Ecto.Migration

  # Intro and credits stay one per file per type. Commercial breaks read from
  # a sidecar .edl file are many per file, so the unique index only covers the
  # detected types. Dropping and recreating an index needs no table rebuild on
  # SQLite, and both adapters support partial indexes, so there is no adapter
  # branching here.

  @name :media_segments_media_file_id_type_index

  def up do
    drop index(:media_segments, [:media_file_id, :type], name: @name)

    create unique_index(:media_segments, [:media_file_id, :type],
             name: @name,
             where: "type IN ('intro', 'credits')"
           )
  end

  def down do
    execute "DELETE FROM media_segments WHERE type NOT IN ('intro', 'credits')"

    drop index(:media_segments, [:media_file_id, :type], name: @name)
    create unique_index(:media_segments, [:media_file_id, :type], name: @name)
  end
end
