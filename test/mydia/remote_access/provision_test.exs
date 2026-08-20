defmodule Mydia.RemoteAccess.ProvisionTest do
  use Mydia.DataCase, async: false

  alias Mydia.RemoteAccess
  alias Mydia.RemoteAccess.Provision

  setup do
    reset_remote_access()
    on_exit(&reset_remote_access/0)
    :ok
  end

  test "creates an enabled config row when none exists" do
    assert RemoteAccess.get_config() == nil

    assert :ok = Provision.run()

    config = RemoteAccess.get_config()
    assert config.enabled
    assert is_binary(config.instance_id)
    assert RemoteAccess.enabled?()
  end

  test "leaves an existing row alone" do
    {:ok, _config} = RemoteAccess.initialize_config()
    {:ok, _config} = RemoteAccess.toggle_remote_access(false)
    instance_id = RemoteAccess.get_config().instance_id

    assert :ok = Provision.run()

    config = RemoteAccess.get_config()
    assert config.instance_id == instance_id
    refute config.enabled
    refute RemoteAccess.enabled?()
  end
end
