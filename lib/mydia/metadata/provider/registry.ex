defmodule Mydia.Metadata.Provider.Registry do
  @moduledoc """
  Registry for metadata provider adapters.

  This module provides a centralized way to register and retrieve metadata
  provider adapter modules based on provider type. It allows runtime selection
  of the appropriate adapter implementation.

  ## Usage

      # Register a provider
      Registry.register(:tmdb, Mydia.Metadata.Provider.TMDB)

      # Get a provider module
      {:ok, provider} = Registry.get_provider(:tmdb)

      # List all registered providers
      providers = Registry.list_providers()
      # => [tmdb: Mydia.Metadata.Provider.TMDB, ...]

      # Check if a provider is registered
      Registry.registered?(:tmdb)
      # => true

  ## Default Providers

  The registry comes pre-configured with adapters for common metadata sources:

    * `:metadata_relay` - Self-hosted metadata relay service (recommended)
    * `:tmdb` - The Movie Database (TMDB) API adapter
    * `:tvdb` - The TV Database (TVDB) API adapter

  Additional providers can be registered at runtime or during application startup.

  ## Configuration-based provider selection

  You can use this module to dynamically select providers based on configuration:

      defmodule MyApp.Metadata do
        alias Mydia.Metadata.Provider.Registry

        def search_media(provider_config, query, opts \\\\ []) do
          with {:ok, provider} <- Registry.get_provider(provider_config.type) do
            provider.search(provider_config, query, opts)
          end
        end
      end
  """

  use Agent

  alias Mydia.Metadata.Provider.Error

  @type provider_type :: atom()
  @type provider_module :: module()

  @doc """
  Starts the registry agent.

  This is typically called during application startup.
  """
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    Agent.start_link(fn -> %{} end, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc """
  Registers a metadata provider adapter.

  ## Examples

      iex> Registry.register(:tmdb, Mydia.Metadata.Provider.TMDB)
      :ok

      iex> Registry.register(:custom_provider, MyApp.CustomProvider)
      :ok
  """
  @spec register(provider_type(), provider_module()) :: :ok
  def register(type, provider_module) when is_atom(type) and is_atom(provider_module) do
    Agent.update(__MODULE__, &Map.put(&1, type, provider_module))
  end

  @doc """
  Gets the provider module for a given provider type.

  Returns `{:ok, module}` if the provider is registered, or `{:error, error}`
  if the provider type is not found.

  ## Examples

      iex> Registry.register(:tmdb, Mydia.Metadata.Provider.TMDB)
      iex> Registry.get_provider(:tmdb)
      {:ok, Mydia.Metadata.Provider.TMDB}

      iex> Registry.get_provider(:unknown_provider)
      {:error, %Error{type: :invalid_config, message: "Unknown provider type: unknown_provider"}}
  """
  @spec get_provider(provider_type()) :: {:ok, provider_module()} | {:error, Error.t()}
  def get_provider(type) when is_atom(type) do
    case Agent.get(__MODULE__, &Map.get(&1, type)) do
      nil ->
        {:error, Error.invalid_config("Unknown provider type: #{type}")}

      provider_module ->
        {:ok, provider_module}
    end
  end

  @doc """
  Gets the provider module for a given provider type, raising if not found.

  ## Examples

      iex> Registry.register(:tmdb, Mydia.Metadata.Provider.TMDB)
      iex> Registry.get_provider!(:tmdb)
      Mydia.Metadata.Provider.TMDB

      iex> Registry.get_provider!(:unknown_provider)
      ** (Mydia.Metadata.Provider.Error) Invalid config: Unknown provider type: unknown_provider
  """
  @spec get_provider!(provider_type()) :: provider_module()
  def get_provider!(type) when is_atom(type) do
    case get_provider(type) do
      {:ok, provider} -> provider
      {:error, error} -> raise error
    end
  end

  @doc """
  Lists all registered providers.

  Returns a keyword list of provider types and their corresponding modules.

  ## Examples

      iex> Registry.list_providers()
      [tmdb: Mydia.Metadata.Provider.TMDB, tvdb: Mydia.Metadata.Provider.TVDB]
  """
  @spec list_providers() :: [{provider_type(), provider_module()}]
  def list_providers do
    Agent.get(__MODULE__, &Map.to_list/1)
  end

  @doc """
  Checks if a provider is registered for the given type.

  ## Examples

      iex> Registry.register(:tmdb, Mydia.Metadata.Provider.TMDB)
      iex> Registry.registered?(:tmdb)
      true

      iex> Registry.registered?(:unknown_provider)
      false
  """
  @spec registered?(provider_type()) :: boolean()
  def registered?(type) when is_atom(type) do
    Agent.get(__MODULE__, &Map.has_key?(&1, type))
  end

  @doc """
  Unregisters a provider.

  This is primarily useful for testing or hot-reloading provider implementations.

  ## Examples

      iex> Registry.register(:tmdb, Mydia.Metadata.Provider.TMDB)
      iex> Registry.unregister(:tmdb)
      :ok
      iex> Registry.registered?(:tmdb)
      false
  """
  @spec unregister(provider_type()) :: :ok
  def unregister(type) when is_atom(type) do
    Agent.update(__MODULE__, &Map.delete(&1, type))
  end

  @doc """
  Clears all registered providers.

  This is primarily useful for testing.

  ## Examples

      iex> Registry.clear()
      :ok
  """
  @spec clear() :: :ok
  def clear do
    Agent.update(__MODULE__, fn _ -> %{} end)
  end
end
