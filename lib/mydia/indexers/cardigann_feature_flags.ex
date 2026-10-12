defmodule Mydia.Indexers.CardigannFeatureFlags do
  @moduledoc """
  Helper module for checking Cardigann indexer feature flag.

  This module handles the ENABLE_CARDIGANN feature flag which controls
  whether Cardigann indexer functionality is available in the application.

  When enabled, Cardigann indexers provide access to hundreds of torrent
  indexers without requiring external Prowlarr/Jackett instances.

  ## Features Controlled

  - UI for browsing and managing Cardigann indexer definitions
  - Background jobs for syncing indexer definitions from GitHub
  - Search integration with Cardigann-based indexers
  - Cardigann indexer results in search responses

  ## Configuration

  The feature flag reads from `:mydia, :features, :cardigann_enabled`
  configuration and defaults to `false` (disabled).

  Set via environment variable:
  - `ENABLE_CARDIGANN=true` - Enable Cardigann indexers
  - `ENABLE_CARDIGANN=false` - Disable Cardigann indexers (default)
  """

  @doc """
  Returns true if Cardigann indexer functionality is enabled, false otherwise.

  Reads from the :cardigann_enabled configuration under the :features key.

  ## Examples

      iex> Mydia.Indexers.CardigannFeatureFlags.enabled?()
      false

      # After setting ENABLE_CARDIGANN=true environment variable
      iex> Mydia.Indexers.CardigannFeatureFlags.enabled?()
      true

  """
  def enabled? do
    Application.get_env(:mydia, :features, [])
    |> Keyword.get(:cardigann_enabled, false)
  end

  @doc """
  The engine the admin chose (or `CARDIGANN_ENGINE` pins): `:builtin` or
  `:prowlarr`. What actually serves searches is `adapter/0`.
  """
  @spec engine() :: :builtin | :prowlarr
  def engine, do: Mydia.Indexers.Cardigann.EngineSetting.setting()

  @doc "The engine serving searches now. It lags `engine/0` while a switch to Prowlarr prepares."
  @spec active_engine() :: :builtin | :prowlarr
  def active_engine, do: Mydia.Indexers.Cardigann.EngineSwitcher.active()

  @doc "The adapter that serves `:cardigann` for the active engine."
  @spec adapter() :: module()
  def adapter do
    if enabled?() and active_engine() == :prowlarr,
      do: Mydia.Indexers.Cardigann.Wasm.Adapter,
      else: Mydia.Indexers.Adapter.Cardigann
  end
end
