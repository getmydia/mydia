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
end
