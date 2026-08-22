defmodule Mydia.Repo.Migrations.AddExternalTorrentsToDownloadClientConfigs do
  use Ecto.Migration

  def change do
    # :text rather than :string. A bare :string is varchar(255) on PostgreSQL
    # and unconstrained TEXT on SQLite, which has shipped the same bug twice.
    #
    # "auto" rather than "adopt" so existing rows keep resolving through
    # Mydia.Downloads.ExternalPolicy rather than freezing today's behaviour at
    # migration time. A client that gains a category later then tightens on its
    # own, which is the upgrade behaviour agreed for issue #531.
    alter table(:download_client_configs) do
      add :external_torrents, :text, default: "auto", null: false
    end
  end
end
