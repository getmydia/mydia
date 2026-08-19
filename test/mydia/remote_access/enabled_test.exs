defmodule Mydia.RemoteAccess.EnabledTest do
  # async: false — :persistent_term is global and is not rolled back by the
  # Ecto sandbox, so a cached value from one test would leak into the next.
  use Mydia.DataCase, async: false

  alias Mydia.RemoteAccess

  setup do
    reset_remote_access()
    on_exit(&reset_remote_access/0)
    :ok
  end

  describe "enabled?/0" do
    test "returns false when no config row exists" do
      refute RemoteAccess.enabled?()
    end

    test "reflects a config row created as enabled" do
      {:ok, _config} = RemoteAccess.initialize_keypair()
      {:ok, _config} = RemoteAccess.toggle_remote_access(true)

      reset_remote_access()

      assert RemoteAccess.enabled?()
    end

    test "picks up toggle_remote_access/1 without a cache reset" do
      {:ok, _config} = RemoteAccess.initialize_keypair()
      {:ok, _config} = RemoteAccess.toggle_remote_access(true)
      assert RemoteAccess.enabled?()

      {:ok, _config} = RemoteAccess.toggle_remote_access(false)
      refute RemoteAccess.enabled?()
    end

    test "picks up upsert_config/1 without a cache reset" do
      {:ok, config} = RemoteAccess.initialize_keypair()
      {:ok, _config} = RemoteAccess.toggle_remote_access(false)
      refute RemoteAccess.enabled?()

      {:ok, _config} =
        RemoteAccess.upsert_config(%{
          instance_id: config.instance_id,
          static_public_key: config.static_public_key,
          static_private_key_encrypted: config.static_private_key_encrypted,
          enabled: true
        })

      assert RemoteAccess.enabled?()
    end
  end

  describe "refresh_enabled_cache/0" do
    test "returns the value it stored" do
      {:ok, _config} = RemoteAccess.initialize_keypair()
      {:ok, _config} = RemoteAccess.toggle_remote_access(true)

      set_remote_access(false)
      refute RemoteAccess.enabled?()

      assert RemoteAccess.refresh_enabled_cache()
      assert RemoteAccess.enabled?()
    end
  end
end
