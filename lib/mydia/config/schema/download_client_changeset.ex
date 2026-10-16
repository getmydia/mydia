defmodule Mydia.Config.Schema.DownloadClientChangeset do
  @moduledoc """
  Changeset for one `Mydia.Config.Schema` download client entry, used by
  `cast_embed(:download_clients, with: ...)`.
  """

  import Ecto.Changeset

  @spec changeset(Ecto.Schema.t(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [
      :name,
      :type,
      :enabled,
      :priority,
      :host,
      :port,
      :use_ssl,
      :url_base,
      :web_ui_url,
      :username,
      :password,
      :api_key,
      :category,
      :download_directory,
      :connection_settings,
      :external_torrents
    ])
    |> validate_required([:name, :type])
    |> validate_inclusion(:type, [
      :qbittorrent,
      :transmission,
      :rqbit,
      :rtorrent,
      :http,
      :sabnzbd,
      :nzbget,
      :blackhole,
      :debrid
    ])
    |> validate_download_client_by_type()
    |> validate_external_torrents()
    |> validate_number(:port, greater_than: 0, less_than: 65536)
    |> validate_number(:priority, greater_than: 0)
  end

  # Network clients need host/port; hostless ones (blackhole, debrid) don't.
  # Debrid additionally needs an api_key and a recognised provider.
  defp validate_download_client_by_type(changeset) do
    case get_field(changeset, :type) do
      :debrid ->
        changeset
        |> validate_required([:api_key])
        |> validate_debrid_provider()

      :blackhole ->
        changeset

      _network_client ->
        validate_required(changeset, [:host, :port])
    end
  end

  # Mirrors DownloadClientConfig.validate_external_torrents/1. The two layers
  # must agree: a combination the admin UI refuses must not be reachable
  # through YAML or an environment variable.
  defp validate_external_torrents(changeset) do
    capable = Mydia.Settings.DownloadClientConfig.category_capable_types()
    type = get_field(changeset, :type)

    if get_field(changeset, :external_torrents) == :category_only and type not in capable do
      add_error(
        changeset,
        :external_torrents,
        "category_only is not supported for #{type} clients, which do not report categories " <>
          "(supported: #{Enum.join(capable, ", ")})"
      )
    else
      changeset
    end
  end

  defp validate_debrid_provider(changeset) do
    providers = Mydia.Settings.DownloadClientConfig.debrid_providers()
    provider = get_field(changeset, :connection_settings)["provider"]

    if provider in providers do
      changeset
    else
      add_error(
        changeset,
        :connection_settings,
        "must include provider (one of: #{Enum.join(providers, ", ")})"
      )
    end
  end
end
