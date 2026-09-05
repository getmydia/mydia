defmodule Mydia.Repo.Migrations.IndexMediaRequestsByTypeAndProviderId do
  use Ecto.Migration

  @moduledoc """
  Supports the type-scoped pending-request lookups in `Mydia.MediaRequests`.

  `check_duplicate_request/1` now asks "is there a pending request of this type
  for this provider id", two predicates where it used to ask one. Both columns
  are nullable and only one is set per row, so these stay plain (non-unique)
  indexes: a request is allowed to be made again after an earlier one was
  rejected, which is what `status` in the index covers.
  """

  def up do
    create index(:media_requests, [:media_type, :tmdb_id, :status],
             name: :media_requests_type_tmdb_id_status_index
           )

    create index(:media_requests, [:media_type, :tvdb_id, :status],
             name: :media_requests_type_tvdb_id_status_index
           )
  end

  def down do
    drop index(:media_requests, [:media_type, :tvdb_id, :status],
           name: :media_requests_type_tvdb_id_status_index
         )

    drop index(:media_requests, [:media_type, :tmdb_id, :status],
           name: :media_requests_type_tmdb_id_status_index
         )
  end
end
