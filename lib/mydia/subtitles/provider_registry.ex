defmodule Mydia.Subtitles.ProviderRegistry do
  @moduledoc """
  Declares the subtitle providers Mydia ships with.

  This is the bottom layer of provider configuration. A provider needing no
  credentials is enabled here, because it costs the operator nothing and works
  with no setup, which is how a fresh install gets more than one upstream. A
  provider needing credentials is declared but left off, because enabling it
  before it is configured only manufactures errors.

  Named `ProviderRegistry` rather than `Registry` so modules aliasing it do not
  shadow Elixir's own `Registry`.
  """

  alias Mydia.Settings.SubtitleProviderConfig

  @builtins [
    %{
      type: :relay,
      name: "Mydia Relay",
      adapter: Mydia.Subtitles.Provider.Relay,
      default_enabled: true,
      default_priority: 30,
      requires_credentials: false
    },
    %{
      type: :opensubtitles,
      name: "OpenSubtitles",
      adapter: Mydia.Subtitles.Provider.OpenSubtitles,
      default_enabled: false,
      default_priority: 10,
      requires_credentials: true
    }
  ]

  @doc """
  Returns every built-in provider declaration.
  """
  @spec builtins() :: [map()]
  def builtins, do: @builtins

  @doc """
  Returns the declaration for a provider type, or nil.
  """
  @spec builtin(atom()) :: map() | nil
  def builtin(type), do: Enum.find(@builtins, &(&1.type == type))

  @doc """
  Returns synthetic configs for providers enabled by default.

  These are the lowest configuration layer. A YAML entry or a database row of the
  same type replaces the synthetic one entirely.
  """
  @spec default_configs() :: [SubtitleProviderConfig.t()]
  def default_configs do
    @builtins
    |> Enum.filter(& &1.default_enabled)
    |> Enum.map(fn builtin ->
      %SubtitleProviderConfig{
        id: "registry::#{builtin.type}",
        name: builtin.name,
        type: builtin.type,
        enabled: true,
        priority: builtin.default_priority,
        connection_settings: %{}
      }
    end)
  end

  @doc """
  Returns the adapter module for a config.

  A config may name its own adapter in `connection_settings["adapter"]`, which
  tests use to inject a stub without touching application environment.
  """
  @spec adapter_for(map()) :: module()
  def adapter_for(config) do
    case Map.get(config, :connection_settings) do
      %{"adapter" => adapter} when is_atom(adapter) and not is_nil(adapter) -> adapter
      _ -> adapter_by_type(Map.get(config, :type))
    end
  end

  defp adapter_by_type(type) do
    case builtin(type) do
      nil -> raise ArgumentError, "no subtitle provider adapter for type #{inspect(type)}"
      builtin -> builtin.adapter
    end
  end
end
