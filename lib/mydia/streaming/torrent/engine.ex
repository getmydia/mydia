defmodule Mydia.Streaming.Torrent.Engine do
  @moduledoc """
  A singleton GenServer that manages the lifecycle of the Rust torrent engine.

  Subscribes to settings:changed PubSub events so flipping
  `streaming.embedded_enabled` from the admin UI takes effect immediately:

    * on -> off: terminate every supervised session, then release the NIF.
    * off -> on: start the NIF on demand.
  """

  use GenServer

  alias Mydia.Torrent
  require Logger

  @name __MODULE__
  @settings_topic "settings:changed"
  @embedded_enabled_key "streaming.embedded_enabled"

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
    Phoenix.PubSub.subscribe(Mydia.PubSub, @settings_topic)

    config = Mydia.Settings.get_streaming_config()

    if config && config.embedded_enabled do
      {:ok, start_engine_resource(%{resource: nil}, config)}
    else
      {:ok, %{resource: nil}}
    end
  end

  @impl true
  def handle_call(:get_resource, _from, state) do
    if state.resource do
      {:reply, {:ok, state.resource}, state}
    else
      {:reply, {:error, state[:error] || :not_enabled}, state}
    end
  end

  @impl true
  def handle_info({:setting_changed, @embedded_enabled_key, value}, state) do
    enabled? = parse_bool(value)

    cond do
      enabled? and is_nil(state.resource) ->
        # Build an effective streaming config that reflects the just-flipped
        # value. The runtime config in :persistent_term may be stale until the
        # next app restart; the DB value is the source of truth.
        config = effective_streaming_config(true)
        {:noreply, start_engine_resource(state, config)}

      not enabled? and not is_nil(state.resource) ->
        Logger.info("Embedded streaming disabled; stopping active torrent sessions and engine")
        stop_all_sessions()
        {:noreply, %{resource: nil}}

      true ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(_other, state), do: {:noreply, state}

  # Internal helpers

  defp start_engine_resource(state, config) do
    staging_dir =
      (config && config.torrent_staging_dir) || "/tmp/mydia/streaming"

    File.mkdir_p!(staging_dir)

    try do
      case Torrent.start_engine(staging_dir) do
        {:ok, resource} ->
          Logger.info("Torrent engine started successfully (staging: #{staging_dir})")
          %{resource: resource}

        {:error, reason} ->
          Logger.error(
            "Torrent engine failed to start: #{inspect(reason)}. " <>
              "Embedded streaming will be disabled."
          )

          Map.merge(state, %{resource: nil, error: reason})
      end
    rescue
      e ->
        Logger.error(
          "Torrent engine crashed during startup:\n" <>
            Exception.format(:error, e, __STACKTRACE__)
        )

        Map.merge(state, %{resource: nil, error: e})
    end
  end

  defp stop_all_sessions do
    for {id, _pid, _meta} <- Mydia.Streaming.Torrent.SessionSupervisor.list_sessions() do
      Mydia.Streaming.Torrent.stop_session(id)
    end
  end

  defp parse_bool(true), do: true
  defp parse_bool(false), do: false
  defp parse_bool("true"), do: true
  defp parse_bool("1"), do: true
  defp parse_bool(_), do: false

  # Build a streaming config that uses the just-flipped value, falling back to
  # whatever else the runtime config carries (staging dir, concurrent cap).
  defp effective_streaming_config(embedded_enabled?) do
    base = Mydia.Settings.get_streaming_config() || %{}

    base
    |> Map.put(:embedded_enabled, embedded_enabled?)
  end
end
