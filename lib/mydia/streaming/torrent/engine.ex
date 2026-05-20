defmodule Mydia.Streaming.Torrent.Engine do
  @moduledoc """
  A singleton GenServer that manages the lifecycle of the Rust torrent engine.
  """

  use GenServer

  alias Mydia.Torrent
  require Logger

  @name __MODULE__

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc """
  Gets the engine resource.
  """
  def get_resource do
    GenServer.call(@name, :get_resource)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Check if embedded streaming is enabled
    config = Mydia.Settings.get_streaming_config()

    if config && config.embedded_enabled do
      staging_dir = config.torrent_staging_dir || "/tmp/mydia/streaming"
      File.mkdir_p!(staging_dir)

      try do
        case Torrent.start_engine(staging_dir) do
          {:ok, resource} ->
            Logger.info("Torrent engine started successfully (staging: #{staging_dir})")
            {:ok, %{resource: resource}}

          {:error, reason} ->
            Logger.error(
              "Torrent engine failed to start: #{inspect(reason)}. " <>
                "Embedded streaming will be disabled."
            )

            {:ok, %{resource: nil, error: reason}}
        end
      rescue
        e ->
          Logger.error(
            "Torrent engine crashed during startup:\n" <>
              Exception.format(:error, e, __STACKTRACE__)
          )

          {:ok, %{resource: nil, error: e}}
      end
    else
      {:ok, %{resource: nil}}
    end
  end

  @impl true
  def handle_call(:get_resource, _from, state) do
    if state.resource do
      {:reply, {:ok, state.resource}, state}
    else
      # Try to start it if it's not started but maybe should be?
      # For now, just return error if not started.
      {:reply, {:error, state[:error] || :not_enabled}, state}
    end
  end
end
