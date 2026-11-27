defmodule Mydia.Config.SmartSpaceTest do
  use ExUnit.Case, async: true

  alias Mydia.Config.Env.SmartSpaceEnv
  alias Mydia.Config.Schema
  alias Mydia.Config.Schema.Paths

  defp changeset(attrs), do: Schema.changeset(%Schema{}, %{"smart_space" => attrs})

  defp env(map), do: SmartSpaceEnv.load(&Map.get(map, &1))

  test "defaults" do
    assert %Schema{smart_space: ss} = Schema.defaults()

    assert %{
             enabled: false,
             unit: "season",
             grace_days: 7,
             watched_by: "all_started",
             selected_users: []
           } = ss
  end

  describe "changeset" do
    test "accepts valid values" do
      assert changeset(%{
               "enabled" => true,
               "unit" => "episode",
               "grace_days" => 0,
               "watched_by" => "selected",
               "selected_users" => ["alice"]
             }).valid?
    end

    test "rejects an unknown unit" do
      refute changeset(%{"unit" => "show"}).valid?
    end

    test "rejects an unknown watched_by" do
      refute changeset(%{"watched_by" => "nobody"}).valid?
    end

    test "rejects negative grace_days" do
      refute changeset(%{"grace_days" => -1}).valid?
    end

    test "rejects selected with no users" do
      refute changeset(%{"watched_by" => "selected", "selected_users" => []}).valid?
    end

    test "allows empty users when watched_by is not selected" do
      assert changeset(%{"watched_by" => "any", "selected_users" => []}).valid?
    end
  end

  describe "SmartSpaceEnv.load/1" do
    test "empty environment yields an empty map" do
      assert env(%{}) == %{}
    end

    test "normalises case on enums" do
      assert env(%{"SMART_SPACE_UNIT" => "Episode"}).unit == "episode"
      assert env(%{"SMART_SPACE_WATCHED_BY" => " ALL_STARTED "}).watched_by == "all_started"
    end

    test "parses boolean and integer" do
      assert %{enabled: true, grace_days: 3} =
               env(%{"SMART_SPACE_ENABLED" => "true", "SMART_SPACE_GRACE_DAYS" => "3"})
    end

    test "unknown enum value becomes :invalid and fails validation by name" do
      loaded = env(%{"SMART_SPACE_UNIT" => "weekly", "SMART_SPACE_WATCHED_BY" => "x"})
      assert loaded.unit == :invalid
      assert loaded.watched_by == :invalid

      cs = Schema.changeset(%Schema{}, %{smart_space: loaded})
      refute cs.valid?

      errors = Ecto.Changeset.traverse_errors(cs, fn {msg, _} -> msg end)
      assert Map.has_key?(errors.smart_space, :unit)
      assert Map.has_key?(errors.smart_space, :watched_by)
    end

    test "selected users are split, trimmed and compacted" do
      assert env(%{"SMART_SPACE_SELECTED_USERS" => " alice, ,bob "}).selected_users ==
               ["alice", "bob"]
    end
  end

  describe "overlay keys" do
    test "cast" do
      assert {:ok, [:smart_space, :selected_users], ["a"]} =
               Paths.cast_overlay("smart_space.selected_users", ["a"])

      assert {:ok, [:smart_space, :enabled], true} =
               Paths.cast_overlay("smart_space.enabled", "true")

      assert {:ok, [:smart_space, :grace_days], 5} =
               Paths.cast_overlay("smart_space.grace_days", "5")
    end
  end
end
