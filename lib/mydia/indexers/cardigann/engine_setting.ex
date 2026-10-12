defmodule Mydia.Indexers.Cardigann.EngineSetting do
  @moduledoc """
  The `cardigann.engine` layered setting: `CARDIGANN_ENGINE` wins over the
  admin choice saved in `config_settings`, which wins over `:builtin`.

  Saving only records the choice. `Mydia.Indexers.Cardigann.EngineSwitcher`
  applies it.
  """

  alias Mydia.Config.Loader
  alias Mydia.Settings

  @env_var "CARDIGANN_ENGINE"
  @setting_key "cardigann.engine"

  @type engine :: :builtin | :prowlarr

  @spec env_var() :: String.t()
  def env_var, do: @env_var

  @spec setting_key() :: String.t()
  def setting_key, do: @setting_key

  @doc "The layered engine choice."
  @spec setting() :: engine()
  def setting do
    case Settings.get_runtime_config() do
      %{cardigann: %{engine: engine}} when engine in [:builtin, :prowlarr] -> engine
      _ -> :builtin
    end
  end

  @doc "Whether `CARDIGANN_ENGINE` is set, which makes the choice read-only."
  @spec env_locked?((String.t() -> String.t() | nil)) :: boolean()
  def env_locked?(getenv \\ &System.get_env/1), do: Settings.env_var_set?(@env_var, getenv)

  @doc "Saves the admin choice and reloads the runtime config."
  @spec save(engine(), keyword()) :: :ok | {:error, term()}
  def save(engine, opts \\ []) when engine in [:builtin, :prowlarr] do
    if env_locked?(Keyword.get(opts, :getenv, &System.get_env/1)) do
      {:error, :env_locked}
    else
      attrs = %{
        key: @setting_key,
        value: Atom.to_string(engine),
        category: :cardigann,
        updated_by_id: Keyword.get(opts, :updated_by_id)
      }

      with {:ok, _setting} <- Settings.upsert_config_setting(attrs),
           {:ok, _config} <- Loader.reload() do
        :ok
      end
    end
  end
end
