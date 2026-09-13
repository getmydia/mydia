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

  def list_pending_removals(configs \\ nil) do
    configs = configs || Settings.list_download_client_configs()

    remove_names =
      configs
      |> Enum.filter(&(&1.remove_completed || false))
      |> Enum.map(& &1.name)

    from(d in Download,
      where:
        not is_nil(d.imported_at) and is_nil(d.client_removed_at) and
          d.download_client in ^remove_names and
          (is_nil(d.match_status) or d.match_status != "unresolved_files")
    )
    |> Repo.all()
  end

  @doc """
  Loads client configs once and returns them with pending removal rows.

  DownloadMonitor should pass the configs into `finish_pending_removal/2`
  so each row does not re-list settings.
  """
  def finish_pending_removals do
    configs = Settings.list_download_client_configs()
    {configs, list_pending_removals(configs)}
  end

  def maybe_remove_after_import(%Download{} = download) do
    if download.match_status == "unresolved_files" do
      :skipped
    else
      case client_info(download) do
        {:error, :missing_client} ->
          # Leave pending: a rename/re-add/adoption may restore the client.
          # Stamp only after remove_download :ok or a confirmed :not_found.
          Logger.warning("Deferring client removal; download client not found",
            download_id: download.id,
            client: download.download_client
          )

          :deferred

        {:ok, %{remove_completed: false}} ->
          :skipped

        {:ok, info} ->
          if seed_aware_type?(info.type) do
            case Client.get_status(info.adapter, info.config, info.client_id) do
              {:ok, %{state: state}} ->
                cond do
                  removable_state?(state) ->
                    remove_and_stamp(download, info)

                  state == :seeding ->
                    Logger.info("Deferring client removal until seeding finishes",
                      download_id: download.id
                    )

                    :deferred

                  state in [:downloading, :checking] ->
                    Logger.info("Deferring client removal; torrent not idle yet",
                      download_id: download.id,
                      state: state
                    )

                    :deferred

                  state == :error ->
                    Logger.warning("Not auto-removing errored torrent after import",
                      download_id: download.id
                    )

                    :deferred

                  true ->
                    Logger.info("Deferring client removal; torrent not idle yet",
                      download_id: download.id,
                      state: state
                    )

                    :deferred
                end

              {:error, error} ->
                if not_found_error?(error) do
                  case stamp(download) do
                    :ok -> :removed
                    {:error, _} = err -> err
                  end
                else
                  Logger.warning("Could not read status for post-import removal",
                    download_id: download.id,
                    error: inspect(error)
                  )

                  :deferred
                end
            end
          else
            remove_and_stamp(download, info)
          end
      end
    end
  end

  def finish_pending_removal(%Download{} = download, configs \\ nil) do
    if download.match_status == "unresolved_files" do
      :skipped
    else
      case client_info(download, configs) do
        {:error, :missing_client} ->
          Logger.warning("Deferring client removal; download client not found",
            download_id: download.id,
            client: download.download_client
          )

          :deferred

        {:ok, info} ->
          if info.remove_completed || false do
            if seed_aware_type?(info.type) do
              case Client.get_status(info.adapter, info.config, info.client_id) do
                {:ok, %{state: state}} ->
                  if removable_state?(state) do
                    remove_and_stamp(download, info)
                  else
                    :still_seeding
                  end

                {:error, error} ->
                  if not_found_error?(error) do
                    case stamp(download) do
                      :ok -> :removed
                      {:error, _} = err -> err
                    end
                  else
                    {:error, error}
                  end
              end
            else
              remove_and_stamp(download, info)
            end
          else
            :skipped
          end
      end
    end
  end

  defp client_info(%Download{} = download, configs \\ nil) do
    if download.download_client && download.download_client_id do
      configs = configs || Settings.list_download_client_configs()

      case Enum.find(configs, &(&1.name == download.download_client)) do
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
             remove_completed: Map.get(client_config, :remove_completed, false) || false
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
        case stamp(download) do
          :ok -> :removed
          {:error, _} = err -> err
        end

      {:error, error} ->
        if not_found_error?(error) do
          case stamp(download) do
            :ok -> :removed
            {:error, _} = err -> err
          end
        else
          {:error, error}
        end
    end
  end

  defp stamp(download) do
    case Downloads.update_download(download, %{
           client_removed_at: DateTime.utc_now() |> DateTime.truncate(:second)
         }) do
      {:ok, _} ->
        :ok

      {:error, reason} = err ->
        Logger.warning("Failed to stamp client_removed_at",
          download_id: download.id,
          error: inspect(reason)
        )

        err
    end
  end
end
