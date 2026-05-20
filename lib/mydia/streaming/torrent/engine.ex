defmodule Mydia.Streaming.Torrent.Engine do
  @moduledoc """
  A singleton GenServer that manages the lifecycle of the Rust torrent engine.
  """

  use GenServer

  alias Mydia.Torrent

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
        resource = Torrent.start_engine(staging_dir)
        {:ok, %{resource: resource}}
      rescue
        e ->
          # We don't want to crash the whole app if the engine fails to start,
          # but we should log it.
          # In a real app, we might want to retry or signal failure.
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
