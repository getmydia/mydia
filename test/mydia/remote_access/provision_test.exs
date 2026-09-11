defmodule Mydia.RemoteAccess.ProvisionTest do
  use Mydia.DataCase, async: true

  alias Mydia.RemoteAccess
  alias Mydia.RemoteAccess.Provision

  test "creates a config row when none exists" do
    assert RemoteAccess.get_config() == nil

    assert :ok = Provision.run()

    assert is_binary(RemoteAccess.get_config().instance_id)
  end

  test "leaves an existing row alone" do
    {:ok, config} = RemoteAccess.initialize_config()

    assert :ok = Provision.run()

    assert RemoteAccess.get_config().instance_id == config.instance_id
  end
end
