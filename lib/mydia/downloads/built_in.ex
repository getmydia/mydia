defmodule Mydia.Downloads.BuiltIn do
  @moduledoc """
  Facade for the built-in torrent client.

  The supervisor stores the engine's address and credentials with
  `put_runtime/1`; `Mydia.Settings.RuntimeConfig.get_runtime_download_clients/0`
  appends `client_configs/0`, so the rest of Mydia sees an ordinary runtime
  client of type `rqbit` driven by `Mydia.Downloads.Client.Rqbit`.
  """

  require Logger

  alias Mydia.Downloads.BuiltIn.Status
  alias Mydia.Downloads.Client.Error
  alias Mydia.Settings.DownloadClientConfig
  alias Mydia.Settings.RuntimeConfig

  @key {__MODULE__, :runtime}
  @name "Built-in"

  def put_runtime(runtime), do: :persistent_term.put(@key, runtime)
  def clear_runtime, do: :persistent_term.erase(@key)
  def runtime, do: :persistent_term.get(@key, nil)

  @doc "The name the built-in client is listed under."
  def name, do: @name

  @doc """
  Whether `name` is the built-in client's, ignoring case and surrounding
  whitespace. Other clients may not use it: lists of clients are merged by
  name, so one would hide the other.
  """
  @spec reserved_name?(term()) :: boolean()
  def reserved_name?(name) when is_binary(name),
    do: String.downcase(String.trim(name)) == String.downcase(@name)

  def reserved_name?(_name), do: false

  @doc """
  Logs, once per boot and `source`, that a client other than the built-in one
  uses its name. Callers run on every client listing, hence the once.
  """
  @spec warn_name_taken(String.t()) :: :ok
  def warn_name_taken(source) do
    key = {__MODULE__, :name_taken_warned, source}

    unless :persistent_term.get(key, false) do
      :persistent_term.put(key, true)

      Logger.warning(
        "A download client from #{source} is named #{inspect(@name)}, which is reserved for " <>
          "the built-in torrent client. Rename it; while the built-in client is active, only the built-in client answers to the name."
      )
    end

    :ok
  end

  @spec client_configs() :: [DownloadClientConfig.t()]
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
