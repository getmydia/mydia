defmodule Mydia.RemoteAccess.ConfigSingletonTest do
  @moduledoc """
  Enabling remote access is an admin toggle, so two tabs could both find no
  config and both insert one. Each insert mints its own instance ID, which the
  unique index on that column cannot collide, so the second row landed and
  every later read raised on the admin page that would have let you fix it.

  These cover both halves of the guard against that: initialization hands back
  an existing row instead of inserting past it, and a read survives a pair of
  rows by taking the older one.
  """
  use Mydia.DataCase, async: false

  alias Mydia.RemoteAccess
  alias Mydia.RemoteAccess.Config
  alias Mydia.Repo

  describe "initialize_config/0" do
    test "creates one config with an instance ID, disabled" do
      assert {:ok, config} = RemoteAccess.initialize_config()

      assert is_binary(config.instance_id)
      refute config.enabled
      assert Repo.aggregate(Config, :count) == 1
    end

    test "returns the existing config rather than inserting a second" do
      assert {:ok, first} = RemoteAccess.initialize_config()
      assert {:ok, second} = RemoteAccess.initialize_config()

      assert second.id == first.id
      assert second.instance_id == first.instance_id
      assert Repo.aggregate(Config, :count) == 1
    end
  end

  describe "get_config/0" do
    test "returns nil before remote access is enabled" do
      assert RemoteAccess.get_config() == nil
    end

    test "returns the oldest row rather than raising when two exist" do
      older = insert_config_at(~U[2026-01-01 00:00:00Z])
      _newer = insert_config_at(~U[2026-06-01 00:00:00Z])

      assert Repo.aggregate(Config, :count) == 2

      config = RemoteAccess.get_config()

      assert config.id == older.id
      assert config.instance_id == older.instance_id
    end
  end

  # Inserted straight through the repo: the point is a pair of rows that
  # initialize_config/0 will no longer produce on its own.
  defp insert_config_at(inserted_at) do
    %Config{}
    |> Config.changeset(%{instance_id: Ecto.UUID.generate(), enabled: false})
    |> Ecto.Changeset.put_change(:inserted_at, inserted_at)
    |> Ecto.Changeset.put_change(:updated_at, inserted_at)
    |> Repo.insert!()
  end
end
