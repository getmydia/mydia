defmodule Mydia.Indexers.CardigannMembershipTest do
  use Mydia.DataCase, async: true

  import Mydia.IndexersFixtures

  alias Mydia.Indexers

  test "add puts a definition in the library and enables it" do
    definition = cardigann_definition_fixture(%{enabled: false})

    assert {:ok, added} = Indexers.add_cardigann_definition(definition)
    assert added.in_library
    assert added.enabled
  end

  test "remove takes it out of the library and keeps its config" do
    definition =
      cardigann_definition_fixture(%{enabled: true, config: %{"username" => "someone"}})

    assert {:ok, removed} = Indexers.remove_cardigann_definition(definition)
    refute removed.in_library
    refute removed.enabled
    assert removed.config == %{"username" => "someone"}
  end

  test "disable keeps a definition in the library" do
    definition = cardigann_definition_fixture(%{enabled: true})

    assert {:ok, disabled} = Indexers.disable_cardigann_definition(definition)
    assert disabled.in_library
    refute disabled.enabled
  end

  test "enable refuses a definition outside the library" do
    definition = cardigann_definition_fixture(%{enabled: false})

    assert {:error, changeset} = Indexers.enable_cardigann_definition(definition)
    assert changeset.errors[:enabled]
  end

  test "lists by library membership, disabled members included" do
    member = cardigann_definition_fixture(%{enabled: true})
    {:ok, disabled_member} = Indexers.disable_cardigann_definition(member)
    outsider = cardigann_definition_fixture(%{enabled: false})

    ids = Indexers.list_cardigann_definitions(in_library: true) |> Enum.map(& &1.id)

    assert disabled_member.id in ids
    refute outsider.id in ids
  end

  test "a disabled member is left out of the enabled listing searches use" do
    {:ok, disabled} =
      cardigann_definition_fixture(%{enabled: true})
      |> Indexers.disable_cardigann_definition()

    ids = Indexers.list_cardigann_definitions(enabled: true) |> Enum.map(& &1.id)
    refute disabled.id in ids
  end

  describe "stored login sessions" do
    alias Mydia.Indexers.CardigannAuth
    alias Mydia.Indexers.CardigannDefinition

    defp with_status(definition, status) do
      definition
      |> CardigannDefinition.health_check_changeset(%{health_status: status})
      |> Mydia.Repo.update!()
    end

    test "saving new config drops the stored session" do
      definition = cardigann_definition_fixture(%{config: %{"cookie" => "old"}})
      {:ok, _} = CardigannAuth.store_session(definition.id, ["a=1"])

      assert {:ok, _} = Indexers.configure_cardigann_definition(definition, %{"cookie" => "new"})
      assert {:error, _} = CardigannAuth.get_stored_session(definition.id)
    end

    test "saving config that did not change keeps the session" do
      definition = cardigann_definition_fixture(%{config: %{"cookie" => "same"}})
      {:ok, _} = CardigannAuth.store_session(definition.id, ["a=1"])

      assert {:ok, _} = Indexers.configure_cardigann_definition(definition, %{"cookie" => "same"})
      assert {:ok, _} = CardigannAuth.get_stored_session(definition.id)
    end

    test "saving new config gives a needs_login definition a fresh attempt" do
      definition = with_status(cardigann_definition_fixture(%{}), "needs_login")

      assert {:ok, saved} =
               Indexers.configure_cardigann_definition(definition, %{"cookie" => "n"})

      assert saved.health_status == "unknown"
    end

    test "saving config leaves other health statuses alone" do
      definition = with_status(cardigann_definition_fixture(%{}), "unhealthy")

      assert {:ok, saved} =
               Indexers.configure_cardigann_definition(definition, %{"cookie" => "n"})

      assert saved.health_status == "unhealthy"
    end

    test "removing a definition from the library drops the stored session" do
      definition = cardigann_definition_fixture(%{})
      {:ok, _} = CardigannAuth.store_session(definition.id, ["a=1"])

      assert {:ok, _} = Indexers.remove_cardigann_definition(definition)
      assert {:error, _} = CardigannAuth.get_stored_session(definition.id)
    end
  end
end
