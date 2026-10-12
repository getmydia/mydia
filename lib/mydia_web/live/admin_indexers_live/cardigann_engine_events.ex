defmodule MydiaWeb.AdminIndexersLive.CardigannEngineEvents do
  @moduledoc """
  The Cardigann engine section of the Indexers page, as LiveView hooks so the
  large `AdminIndexersLive.Index` gains only one line of wiring.

  Needs the `:cardigann_enabled` and `:current_user` assigns. The switcher is
  not started while Cardigann is disabled, so every event is ignored then.
  """

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView

  alias Mydia.Indexers.Cardigann.EngineSwitcher
  alias MydiaWeb.AdminIndexersLive.CardigannEngineComponents

  @events [
    "switch_cardigann_engine",
    "retry_cardigann_engine",
    "remove_cardigann_engine_cache"
  ]

  @spec attach(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def attach(socket) do
    socket
    |> subscribe()
    |> load()
    |> attach_hook(:cardigann_engine_events, :handle_event, &handle_event/3)
    |> attach_hook(:cardigann_engine_info, :handle_info, &handle_info/2)
  end

  @doc "Loads the engine status and cache size, or clears them while Cardigann is disabled."
  @spec load(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def load(socket) do
    if socket.assigns.cardigann_enabled do
      assign(socket,
        cardigann_engine: EngineSwitcher.status(),
        cardigann_cache_bytes: EngineSwitcher.cache_bytes()
      )
    else
      assign(socket, cardigann_engine: nil, cardigann_cache_bytes: 0)
    end
  end

  defp subscribe(socket) do
    if connected?(socket) and socket.assigns.cardigann_enabled,
      do: Phoenix.PubSub.subscribe(Mydia.PubSub, EngineSwitcher.topic())

    socket
  end

  defp handle_event(event, _params, %{assigns: %{cardigann_enabled: false}} = socket)
       when event in @events do
    {:halt, socket}
  end

  defp handle_event("switch_cardigann_engine", %{"engine" => engine}, socket)
       when engine in ["builtin", "prowlarr"] do
    engine = String.to_existing_atom(engine)

    case EngineSwitcher.switch(engine, updated_by_id: socket.assigns.current_user.id) do
      :ok ->
        {:halt, load(socket)}

      {:error, :env_locked} ->
        {:halt, put_flash(socket, :error, "The engine is set by CARDIGANN_ENGINE")}

      {:error, reason} ->
        {:halt, put_flash(socket, :error, "Could not switch engine: #{inspect(reason)}")}
    end
  end

  # Only a forged event gets here; the page offers only the two engines.
  defp handle_event("switch_cardigann_engine", _params, socket),
    do: {:halt, put_flash(socket, :error, "Unknown engine")}

  defp handle_event("retry_cardigann_engine", _params, socket) do
    EngineSwitcher.retry_now()
    {:halt, socket}
  end

  defp handle_event("remove_cardigann_engine_cache", _params, socket) do
    case EngineSwitcher.remove_cache() do
      {:ok, bytes} ->
        {:halt,
         socket
         |> put_flash(
           :info,
           "Removed the cached Prowlarr engine (#{CardigannEngineComponents.format_mb(bytes)})"
         )
         |> load()}

      {:error, :in_use} ->
        {:halt, put_flash(socket, :error, "The Prowlarr engine is in use")}
    end
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  defp handle_info({:cardigann_engine, status}, socket) do
    {:halt,
     socket
     |> assign(cardigann_engine: status, cardigann_cache_bytes: EngineSwitcher.cache_bytes())}
  end

  defp handle_info(_message, socket), do: {:cont, socket}
end
