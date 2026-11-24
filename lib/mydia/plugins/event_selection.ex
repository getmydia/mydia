defmodule Mydia.Plugins.EventSelection do
  @moduledoc """
  Per-instance choice of which of a plugin's subscribed events it receives.

  A plugin opts in by declaring a settings field of type `events`. The saved
  value is a list of event names (or a comma separated string). The result is
  always a subset of `plugin.events`, in `plugin.events` order. A plugin without
  such a field receives everything it subscribed to.
  """

  alias Mydia.Plugins.{Manifest, Plugin}

  @doc "The events an instance with these settings receives."
  @spec selected(Plugin.t(), map()) :: [String.t()]
  def selected(%Plugin{event_selection: nil, events: events}, _settings), do: events

  def selected(%Plugin{events: events, event_selection: %{key: key, default: default}}, settings) do
    chosen =
      case Map.fetch(settings || %{}, key) do
        {:ok, value} when not is_nil(value) -> parse(value)
        _ -> default
      end

    case chosen do
      nil -> events
      list -> Enum.filter(events, &(&1 in list))
    end
  end

  @doc "True when an instance with these settings receives `event_type`."
  @spec wants?(Plugin.t(), map(), String.t()) :: boolean()
  def wants?(%Plugin{} = plugin, settings, event_type),
    do: event_type in selected(plugin, settings)

  @doc """
  Sets the events field to the full `events:subscribe` list when the manifest
  declares one and the settings do not carry it yet. Otherwise unchanged.
  """
  @spec seed(map(), map()) :: map()
  def seed(manifest, settings) do
    with %{key: key} <- Manifest.event_selection_field(Map.get(manifest, "settings_schema", [])),
         false <- Map.has_key?(settings, key) do
      Map.put(settings, key, get_in(manifest, ["capabilities", "events:subscribe"]) || [])
    else
      _ -> settings
    end
  end

  defp parse(list) when is_list(list), do: Enum.filter(list, &is_binary/1)

  defp parse(value) when is_binary(value),
    do: value |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  defp parse(_), do: []
end
