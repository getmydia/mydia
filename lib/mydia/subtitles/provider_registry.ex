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
    },
    %{
      type: :gestdown,
      name: "Gestdown",
      adapter: Mydia.Subtitles.Provider.Gestdown,
      default_enabled: true,
      default_priority: 20,
      requires_credentials: false
    },
    %{
      type: :subdl,
      name: "SubDL",
      adapter: Mydia.Subtitles.Provider.SubDL,
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
  tests use to inject a stub without touching application environment. The value
  may arrive as a module atom (in-memory) or as a string (after a JSON column
  round-trip); only already-loaded modules are accepted from strings.
  """
  @spec adapter_for(map()) :: module()
  def adapter_for(config) do
    case Map.get(config, :connection_settings) do
      %{"adapter" => adapter} when is_atom(adapter) and not is_nil(adapter) ->
        adapter

      %{"adapter" => adapter} when is_binary(adapter) and adapter != "" ->
        resolve_adapter_string(adapter, config)

      _ ->
        adapter_by_type(Map.get(config, :type))
    end
  end

  # `connection_settings` is operator-editable, so a name arriving here is only
  # honoured when it resolves to a loaded module that actually implements the
  # provider behaviour. Otherwise this would be a way to point the chain at any
  # module in the release and call search/2 on it.
  defp resolve_adapter_string(adapter, config) do
    module = String.to_existing_atom(adapter)

    if provider_adapter?(module) do
      module
    else
      adapter_by_type(Map.get(config, :type))
    end
  rescue
    ArgumentError -> adapter_by_type(Map.get(config, :type))
  end

  # The whole callback surface, not just the two the chain happens to call
  # first. A module satisfying only those would pass here and then crash at
  # download time, which is a worse failure than refusing the override outright.
  @required_callbacks [search: 2, download: 2, validate_config: 1, quota_info: 1, capabilities: 0]

  defp provider_adapter?(module) do
    Code.ensure_loaded?(module) and
      Enum.all?(@required_callbacks, fn {fun, arity} ->
        function_exported?(module, fun, arity)
      end)
  end

  defp adapter_by_type(type) do
    case builtin(type) do
      nil -> raise ArgumentError, "no subtitle provider adapter for type #{inspect(type)}"
      builtin -> builtin.adapter
    end
  end
end
