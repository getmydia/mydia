defmodule Mydia.Repo.Migrations.AddWebUiUrlToDownloadClientConfigs do
  use Ecto.Migration

  def change do
    # The address the operator's browser uses to open the client, which in a
    # Docker setup is rarely the host:port Mydia itself connects to. :text, not
    # :string: see priv/repo/README.md.
    alter table(:download_client_configs) do
      add :web_ui_url, :text
    end
  end
end
