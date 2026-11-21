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

  alias Mydia.Config.Loader
  alias Mydia.Settings

  @cache_key {__MODULE__, :enabled}
  @env_var "ENABLE_REMOTE_ACCESS"
  @setting_key "remote_access.enabled"
  @relay_env_var "IROH_RELAY_URL"
  @relay_setting_key "remote_access.relay_urls"
  @child_id Mydia.Player.RemoteAccess.Supervisor

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

  @doc """
  Saves the admin toggle, then starts or stops the p2p subtree to match.
  Concurrent calls run one after another, so the subtree always ends up
  matching the last value saved.

  Options:

    * `:updated_by_id` - the administrator making the change
    * `:getenv` - replaces `System.get_env/1`, so tests never set real env vars
    * `:supervisor` - the parent of the remote-access subtree, by default
      `Mydia.Player.Supervisor`
  """
  @spec set_enabled(boolean(), keyword()) :: :ok | {:error, term()}
  def set_enabled(enabled, opts \\ []) when is_boolean(enabled) do
    getenv = Keyword.get(opts, :getenv, &System.get_env/1)

    cond do
      not Mydia.Player.enabled?() -> {:error, :player_disabled}
      env_locked?(getenv) -> {:error, :env_locked}
      true -> save_and_sync(enabled, opts)
    end
  end

  # One save at a time, under a node-local lock. Two administrators saving
  # together could otherwise interleave, and a stale "off" stop the subtree
  # after a newer "on" had started it, leaving the setting on with no p2p node.
  defp save_and_sync(enabled, opts) do
    :global.trans({__MODULE__, self()}, fn -> do_save_and_sync(enabled, opts) end, [node()])
  end

  # The cache is reseeded before the subtree changes, so request handlers
  # refuse from the moment an administrator switches remote access off.
  defp do_save_and_sync(enabled, opts) do
    attrs = %{
      key: @setting_key,
      value: to_string(enabled),
      category: :remote_access,
      updated_by_id: Keyword.get(opts, :updated_by_id)
    }

    with {:ok, _setting} <- Settings.upsert_config_setting(attrs),
         {:ok, _config} <- Loader.reload() do
      refresh()
      sync(enabled, Keyword.get(opts, :supervisor, Mydia.Player.Supervisor))
    end
  end

  @doc """
  Starts or stops the remote-access subtree under `supervisor` to match
  `enabled`.

  Restarting works on a child whose `init/1` returned `:ignore` at boot,
  because a supervisor keeps the spec of a non-temporary child that ignored.
  The restarted `init/1` asks `refresh/0` again, so a subtree the environment
  does not allow to start stays down.
  """
  @spec sync(boolean(), Supervisor.supervisor()) :: :ok | {:error, term()}
  def sync(enabled, supervisor \\ Mydia.Player.Supervisor)

  def sync(true, supervisor) do
    case Supervisor.restart_child(supervisor, @child_id) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, :running} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def sync(false, supervisor) do
    case Supervisor.terminate_child(supervisor, @child_id) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  @doc "The environment variable that sets the custom relays and locks the field."
  @spec relay_env_var() :: String.t()
  def relay_env_var, do: @relay_env_var

  @doc "The `config_settings` key the custom relay field writes."
  @spec relay_setting_key() :: String.t()
  def relay_setting_key, do: @relay_setting_key

  @doc """
  The layered `remote_access.relay_urls`: the iroh relays this install uses
  instead of mydia's. Empty means mydia's (see `Mydia.P2p.RelayList`).
  """
  @spec relay_urls() :: [String.t()]
  def relay_urls do
    case Settings.get_runtime_config() do
      %{remote_access: %{relay_urls: urls}} when is_list(urls) -> urls
      _ -> []
    end
  end

  @doc "Whether `IROH_RELAY_URL` is set, which makes the relay field read-only."
  @spec relay_env_locked?((String.t() -> String.t() | nil)) :: boolean()
  def relay_env_locked?(getenv \\ &System.get_env/1),
    do: Mydia.Settings.env_var_set?(@relay_env_var, getenv)

  @doc """
  Saves the custom relay list, then restarts the p2p subtree if it is running,
  so the node rejoins on the new relays without a server restart. An empty
  list deletes the row, which hands the choice back to mydia's list.

  Takes the same lock and options as `set_enabled/2`.
  """
  @spec set_relay_urls([String.t()], keyword()) :: :ok | {:error, term()}
  def set_relay_urls(urls, opts \\ []) when is_list(urls) do
    getenv = Keyword.get(opts, :getenv, &System.get_env/1)
    urls = urls |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    cond do
      relay_env_locked?(getenv) ->
        {:error, :env_locked}

      bad = Enum.find(urls, &(not Mydia.Config.Schema.RemoteAccess.relay_url?(&1))) ->
        {:error, {:invalid_url, bad}}

      true ->
        :global.trans(
          {__MODULE__, self()},
          fn -> do_save_relays(urls, opts) end,
          [node()]
        )
    end
  end

  defp do_save_relays(urls, opts) do
    with :ok <- write_relays(urls, Keyword.get(opts, :updated_by_id)),
         {:ok, _config} <- Loader.reload() do
      # Saved either way by now, so a failed restart is its own error: the
      # caller must not report the relay as unsaved.
      case restart_if_running(Keyword.get(opts, :supervisor, Mydia.Player.Supervisor)) do
        :ok -> :ok
        {:error, reason} -> {:error, {:restart_failed, reason}}
      end
    end
  end

  defp write_relays([], _updated_by_id) do
    case Settings.get_config_setting_by_key(@relay_setting_key) do
      nil -> :ok
      setting -> setting |> Settings.delete_config_setting() |> ok()
    end
  end

  defp write_relays(urls, updated_by_id) do
    %{
      key: @relay_setting_key,
      value: Enum.join(urls, ","),
      category: :remote_access,
      updated_by_id: updated_by_id
    }
    |> Settings.upsert_config_setting()
    |> ok()
  end

  defp ok({:ok, _}), do: :ok
  defp ok({:error, _} = error), do: error

  # The relay list is read once, when Mydia.P2p.Server starts its host, so a
  # running node only sees a new one by starting over. A stopped subtree
  # (remote access off, or a test environment) picks it up when it next starts.
  defp restart_if_running(supervisor) do
    running? =
      supervisor
      |> Supervisor.which_children()
      |> Enum.any?(fn {id, pid, _, _} -> id == @child_id and is_pid(pid) end)

    if running? do
      with :ok <- sync(false, supervisor), do: sync(true, supervisor)
    else
      :ok
    end
  catch
    # No supervisor at all: the player subtree never started.
    :exit, _ -> :ok
  end

  defp startable? do
    :mydia
    |> Application.get_env(Mydia.Player, [])
    |> Keyword.get(:start_remote_access, true)
  end
end
