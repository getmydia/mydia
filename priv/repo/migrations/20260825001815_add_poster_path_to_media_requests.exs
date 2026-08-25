defmodule Mydia.Repo.Migrations.AddPosterPathToMediaRequests do
  use Ecto.Migration

  def change do
    # :text rather than :string. A bare :string is varchar(255) on PostgreSQL
    # and unconstrained TEXT on SQLite, and TVDB stores a full artwork URL
    # here rather than a short relative path.
    alter table(:media_requests) do
      add :poster_path, :text
    end
  end
end
