defmodule Mydia.Downloads.ClientRemoval do
  @moduledoc """
  Deferred Remove After Import cleanup.

  Seed-aware torrent clients keep seeding until paused/completed/gone;
  other clients remove immediately when `remove_completed` is set.
  """

  require Logger

  import Ecto.Query

  alias Mydia.Downloads
  alias Mydia.Downloads.Client
  alias Mydia.Downloads.Client.Error
  alias Mydia.Downloads.Client.Registry
  alias Mydia.Downloads.Download
  alias Mydia.Repo
  alias Mydia.Settings

  @seed_aware ~w(qbittorrent transmission rtorrent)a

  def seed_aware_type?(type) when is_atom(type), do: type in @seed_aware

  def removable_state?(state) when state in [:paused, :completed], do: true
  def removable_state?(_), do: false

  def not_found_error?(%Error{type: :not_found}), do: true
  def not_found_error?(_), do: false

  def list_pending_removals do
    remove_names =
      Settings.list_download_client_configs()
      |> Enum.filter(& &1.remove_completed)
      |> Enum.map(& &1.name)

    from(d in Download,
      where:
        not is_nil(d.imported_at) and is_nil(d.client_removed_at) and
          d.download_client in ^remove_names
    )
    |> Repo.all()
  end

  def maybe_remove_after_import(%Download{} = download) do
    case client_info(download) do
      {:error, :missing_client} ->
        stamp(download)
        :removed

      {:ok, %{remove_completed: false}} ->
        :skipped

      {:ok, info} ->
        cond do
          not seed_aware_type?(info.type) ->
            remove_and_stamp(download, info)

          true ->
            case Client.get_status(info.adapter, info.config, info.client_id) do
              {:ok, %{state: state}} when state in [:paused, :completed] ->
                remove_and_stamp(download, info)

              {:ok, %{state: :seeding}} ->
                Logger.info("Deferring client removal until seeding finishes",
                  download_id: download.id
                )

                :deferred

              {:ok, %{state: state}} when state in [:downloading, :checking] ->
                Logger.info("Deferring client removal; torrent not idle yet",
                  download_id: download.id,
                  state: state
                )

                :deferred

              {:ok, %{state: :error}} ->
                Logger.warning("Not auto-removing errored torrent after import",
                  download_id: download.id
                )

                :deferred

              {:ok, %{state: state}} ->
                Logger.info("Deferring client removal; torrent not idle yet",
                  download_id: download.id,
                  state: state
                )

                :deferred

              {:error, error} ->
                if not_found_error?(error) do
                  stamp(download)
                  :removed
                else
                  Logger.warning("Could not read status for post-import removal",
                    download_id: download.id,
                    error: inspect(error)
                  )

                  :deferred
                end
            end
        end
    end
  end

  def finish_pending_removal(%Download{} = download) do
    case client_info(download) do
      {:error, :missing_client} ->
        stamp(download)
        :removed

      {:ok, info} ->
        unless info.remove_completed do
          :skipped
        else
          case Client.get_status(info.adapter, info.config, info.client_id) do
            {:ok, %{state: state}} ->
              if removable_state?(state) do
                remove_and_stamp(download, info)
              else
                :still_seeding
              end

            {:error, error} ->
              if not_found_error?(error) do
                stamp(download)
                :removed
              else
                {:error, error}
              end
          end
        end
    end
  end

  defp client_info(%Download{} = download) do
    if download.download_client && download.download_client_id do
      case Settings.list_download_client_configs()
           |> Enum.find(&(&1.name == download.download_client)) do
        nil ->
          {:error, :missing_client}

        client_config ->
          adapter = Registry.lookup(client_config.type)

          {:ok,
           %{
             type: client_config.type,
             adapter: adapter,
             config: build_client_config(client_config),
             client_id: download.download_client_id,
             remove_completed: Map.get(client_config, :remove_completed, false)
           }}
      end
    else
      {:error, :missing_client}
    end
  end

  defp build_client_config(client_config) do
    case client_config.type do
      :blackhole ->
        %{
          type: :blackhole,
          connection_settings: client_config.connection_settings || %{}
        }

      :debrid ->
        %{
          type: :debrid,
          api_key: client_config.api_key,
          download_directory: client_config.download_directory,
          connection_settings: client_config.connection_settings || %{}
        }

      _ ->
        %{
          type: client_config.type,
          host: client_config.host,
          port: client_config.port,
          username: client_config.username,
          password: client_config.password,
          use_ssl: client_config.use_ssl || false,
          options:
            %{}
            |> maybe_put(:url_base, client_config.url_base)
            |> maybe_put(:api_key, client_config.api_key)
        }
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp remove_and_stamp(download, info) do
    case Client.remove_download(
           info.adapter,
           info.config,
           info.client_id,
           delete_files: true
         ) do
      :ok ->
        stamp(download)
        :removed

      {:error, error} ->
        if not_found_error?(error) do
          stamp(download)
          :removed
        else
          {:error, error}
        end
    end
  end

  defp stamp(download) do
    {:ok, _} =
      Downloads.update_download(download, %{
        client_removed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
  end
end
