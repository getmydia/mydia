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
  Returns which engine runs Cardigann definitions: `:builtin` (the Elixir
  engine, the default) or `:prowlarr` (Prowlarr's engine compiled to wasm).

  Set via `CARDIGANN_ENGINE=builtin|prowlarr`. `ENABLE_CARDIGANN=false`
  disables Cardigann whatever the engine is.
  """
  @spec engine() :: :builtin | :prowlarr
  def engine do
    Application.get_env(:mydia, :features, [])
    |> Keyword.get(:cardigann_engine, :builtin)
  end

  @doc """
  True when the wasm engine is both selected and Cardigann is enabled: the only
  case in which the engine process starts, fetches or compiles anything.
  """
  @spec wasm_engine?() :: boolean()
  def wasm_engine?, do: enabled?() and engine() == :prowlarr

  @doc """
  The active engine and whether it can serve searches, for status displays.

  `state` is `:ready`, `:starting` (selected, still being prepared) or
  `:unavailable`; `detail` names the reason when it is not ready.
  """
  @spec engine_status() :: %{
          engine: :builtin | :prowlarr,
          label: String.t(),
          state: :ready | :starting | :unavailable,
          detail: String.t() | nil
        }
  def engine_status do
    case engine() do
      :builtin ->
        %{engine: :builtin, label: "Built-in engine", state: :ready, detail: nil}

      :prowlarr ->
        label = "Prowlarr engine (wasm)"

        case Mydia.Indexers.Cardigann.Wasm.Engine.status() do
          :ready ->
            %{engine: :prowlarr, label: label, state: :ready, detail: nil}

          status when status in [:pending, :compiling] ->
            %{
              engine: :prowlarr,
              label: label,
              state: :starting,
              detail: "still being prepared, searches fail until it is ready"
            }

          :disabled ->
            %{
              engine: :prowlarr,
              label: label,
              state: :unavailable,
              detail: "the engine is not running"
            }

          {:unavailable, reason} ->
            %{engine: :prowlarr, label: label, state: :unavailable, detail: reason}
        end
    end
  end
end
