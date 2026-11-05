defmodule Mydia.Downloads.BuiltIn do
  @moduledoc """
  Facade for the built-in torrent client.

  The supervisor stores the engine's address and credentials with
  `put_runtime/1`; `Mydia.Settings.RuntimeConfig.get_runtime_download_clients/0`
  appends `client_configs/0`, so the rest of Mydia sees an ordinary runtime
  client of type `rqbit` driven by `Mydia.Downloads.Client.Rqbit`.
  """

  alias Mydia.Downloads.BuiltIn.Status
  alias Mydia.Downloads.Client.Error
  alias Mydia.Settings.DownloadClientConfig
  alias Mydia.Settings.RuntimeConfig

  @key {__MODULE__, :runtime}
  @name "Built-in"

  def put_runtime(runtime), do: :persistent_term.put(@key, runtime)
  def clear_runtime, do: :persistent_term.erase(@key)
  def runtime, do: :persistent_term.get(@key, nil)

  # Not DownloadClientConfig.t(): a runtime client has no inserted_at or
  # updated_at, which that type declares as DateTime.t().
  @spec client_configs() :: [%DownloadClientConfig{}]
  def client_configs do
    case runtime() do
      nil ->
        []

      %{api_port: port, credentials: {user, pass}, config: config} ->
        [
          %DownloadClientConfig{
            id: RuntimeConfig.build_runtime_id(:download_client, @name),
            name: @name,
            type: :rqbit,
            enabled: true,
            priority: 10,
            host: "127.0.0.1",
            port: port,
            use_ssl: false,
            username: user,
            password: pass,
            download_directory: config.download_path,
            connection_settings: %{"managed" => true},
            external_torrents: :auto
          }
        ]
    end
  end

  @spec managed?(map()) :: boolean()
  def managed?(config) do
    options = Map.get(config, :options) || Map.get(config, :connection_settings) || %{}
    Map.get(options, "managed") == true or Map.get(options, :managed) == true
  end

  @spec guard(map(), GenServer.server()) :: :ok | {:error, Error.t()}
  def guard(config, status_server \\ Status) do
    with true <- managed?(config),
         reason when not is_nil(reason) <- Status.blocking_reason(Status.get(status_server)) do
      {:error, Error.connection_failed(Status.describe(reason), %{built_in: reason})}
    else
      _ -> :ok
    end
  catch
    :exit, _ -> {:error, Error.connection_failed(Status.describe(:engine_starting))}
  end
end
