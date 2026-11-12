defmodule Mydia.Downloads.BuiltIn do
  @moduledoc """
  Facade for the built-in torrent client.

  `BuiltIn.Manager` stores the engine's address and credentials with
  `put_runtime/1`; `Mydia.Settings.RuntimeConfig.get_runtime_download_clients/0`
  appends `client_configs/0`, so the rest of Mydia sees an ordinary runtime
  client of type `rqbit` driven by `Mydia.Downloads.Client.Rqbit`.
  """

  alias Mydia.Downloads.BuiltIn.{Runtime, Status}
  alias Mydia.Downloads.Client.Error
  alias Mydia.Settings.DownloadClientConfig
  alias Mydia.Settings.RuntimeConfig

  @key {__MODULE__, :runtime}
  @name "Built-in"

  @spec put_runtime(Runtime.t()) :: :ok
  def put_runtime(%Runtime{} = runtime), do: :persistent_term.put(@key, runtime)
  def clear_runtime, do: :persistent_term.erase(@key)
  @spec runtime() :: Runtime.t() | nil
  def runtime, do: :persistent_term.get(@key, nil)

  @doc "The name the built-in client is listed under."
  def name, do: @name

  @doc """
  Whether `name` is the built-in client's, ignoring case and surrounding
  whitespace. Other clients may not use it: clients are merged and looked up
  by name, so downloads of one would be routed to the other. `BuiltIn.Manager`
  therefore leaves the built-in client off while another client has the name.
  """
  @spec reserved_name?(term()) :: boolean()
  def reserved_name?(name) when is_binary(name),
    do: String.downcase(String.trim(name)) == String.downcase(@name)

  def reserved_name?(_name), do: false

  @spec client_configs() :: [DownloadClientConfig.t()]
  def client_configs do
    case runtime() do
      nil ->
        []

      %Runtime{api_port: port, credentials: {user, pass}, config: config} ->
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
