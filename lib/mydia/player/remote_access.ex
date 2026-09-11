defmodule Mydia.Player.RemoteAccess do
  @moduledoc """
  The remote-access switch: whether this server runs its p2p node, accepts
  pairing and honours media tokens.

  The setting is `remote_access.enabled` in the layered config, so
  `ENABLE_REMOTE_ACCESS` wins over the admin toggle, which wins over the
  default of on. It only counts while the player is on (`Mydia.Player`).

  `enabled?/0` sits on the request path (media-token auth and the p2p request
  handlers), so its answer is cached in `:persistent_term`. Any test that
  reads or writes the cache must be `async: false`.
  """

  alias Mydia.Settings

  @cache_key {__MODULE__, :enabled}
  @env_var "ENABLE_REMOTE_ACCESS"
  @setting_key "remote_access.enabled"

  @doc "The environment variable that controls the setting and locks the toggle."
  @spec env_var() :: String.t()
  def env_var, do: @env_var

  @doc "The `config_settings` key the admin toggle writes."
  @spec setting_key() :: String.t()
  def setting_key, do: @setting_key

  @doc "The layered `remote_access.enabled` value: env, then database, then on."
  @spec setting() :: boolean()
  def setting do
    case Settings.get_runtime_config() do
      %{remote_access: %{enabled: enabled}} when is_boolean(enabled) -> enabled
      _ -> true
    end
  end

  @doc """
  Whether `ENABLE_REMOTE_ACCESS` is set, which makes the toggle read-only.

  Empty means unset, the same test `Mydia.Settings.config_source/3` and the
  Loader's `put_if_present/4` apply, so the lock and the ENV badge agree with
  what actually controls the setting. `getenv` replaces `System.get_env/1` in
  tests, which must never set a real environment variable.
  """
  @spec env_locked?((String.t() -> String.t() | nil)) :: boolean()
  def env_locked?(getenv \\ &System.get_env/1), do: Mydia.Settings.env_var_set?(@env_var, getenv)

  @doc """
  Whether remote access is live for this boot: the player is on, the setting
  is on, and this environment lets the p2p node start. `config/test.exs`
  turns the last one off so `mix test` never opens an iroh endpoint.

  Cached. An empty cache is filled on first read, which also covers a boot
  where the player subtree never started.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    case :persistent_term.get(@cache_key, :unset) do
      :unset -> refresh()
      value -> value
    end
  end

  @doc "Recomputes `enabled?/0` from the current config and caches the answer."
  @spec refresh() :: boolean()
  def refresh do
    value = Mydia.Player.enabled?() and setting() and startable?()
    :persistent_term.put(@cache_key, value)
    value
  end

  defp startable? do
    :mydia
    |> Application.get_env(Mydia.Player, [])
    |> Keyword.get(:start_remote_access, true)
  end
end
