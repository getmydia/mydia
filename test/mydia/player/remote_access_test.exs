defmodule Mydia.Player.RemoteAccessTest do
  # async: false - the cache is :persistent_term and every input is
  # application env. The sandbox rolls back neither.
  use Mydia.DataCase, async: false

  alias Mydia.Config.Schema.Paths
  alias Mydia.Player
  alias Mydia.Player.RemoteAccess

  setup do
    runtime_config = Application.get_env(:mydia, :runtime_config)
    player_env = Application.fetch_env(:mydia, Mydia.Player)

    on_exit(fn ->
      Application.put_env(:mydia, :runtime_config, runtime_config)
      restore_env(Mydia.Player, player_env)
      clear_cache()
    end)

    clear_cache()
    :ok
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:mydia, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:mydia, key)

  defp clear_cache, do: :persistent_term.erase({RemoteAccess, :enabled})

  defp put_setting(enabled) do
    config = Mydia.Settings.get_runtime_config()
    Application.put_env(:mydia, :runtime_config, put_in(config.remote_access.enabled, enabled))
  end

  defp allow_start(allowed) do
    Application.put_env(:mydia, Mydia.Player, start_remote_access: allowed)
  end

  test "remote_access.enabled is a key the admin toggle may write" do
    assert Paths.known?(RemoteAccess.setting_key())
  end

  describe "setting/0" do
    test "reads the layered value" do
      put_setting(false)
      refute RemoteAccess.setting()

      put_setting(true)
      assert RemoteAccess.setting()
    end
  end

  describe "refresh/0" do
    test "is on when the player, the setting and the environment all allow it" do
      allow_start(true)
      put_setting(true)

      assert RemoteAccess.refresh()
      assert Player.remote_access_enabled?()
    end

    test "is off when the setting is off" do
      allow_start(true)
      put_setting(false)

      refute RemoteAccess.refresh()
      refute Player.remote_access_enabled?()
    end

    test "is off when the player is off, whatever the setting says" do
      allow_start(true)
      put_setting(true)
      disable_player()

      refute RemoteAccess.refresh()
    end

    test "is off under mix test's default" do
      allow_start(false)
      put_setting(true)

      refute RemoteAccess.refresh()
    end
  end

  describe "enabled?/0" do
    test "fills an empty cache on first read" do
      allow_start(true)
      put_setting(true)

      assert RemoteAccess.enabled?()
    end

    test "answers from the cache until refreshed" do
      allow_start(true)
      put_setting(true)
      assert RemoteAccess.enabled?()

      put_setting(false)
      assert RemoteAccess.enabled?()

      refute RemoteAccess.refresh()
      refute RemoteAccess.enabled?()
    end
  end

  describe "env_locked?/1" do
    test "is locked whenever the variable is present, even empty" do
      assert RemoteAccess.env_locked?(fn "ENABLE_REMOTE_ACCESS" -> "true" end)
      assert RemoteAccess.env_locked?(fn "ENABLE_REMOTE_ACCESS" -> "" end)
      refute RemoteAccess.env_locked?(fn "ENABLE_REMOTE_ACCESS" -> nil end)
    end
  end
end
