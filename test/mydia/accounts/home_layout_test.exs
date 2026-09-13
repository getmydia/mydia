defmodule Mydia.Accounts.HomeLayoutTest do
  use ExUnit.Case, async: true

  alias Mydia.Accounts.HomeLayout
  alias Mydia.Accounts.HomeLayout.Widget
  alias Mydia.Accounts.User

  describe "catalog/0" do
    test "returns all nine widgets in default display order" do
      catalog = HomeLayout.catalog()

      assert length(catalog) == 9
      assert Enum.all?(catalog, &match?(%Widget{}, &1))

      assert Enum.map(catalog, & &1.key) == [
               :library_stats,
               :system_health,
               :quick_actions,
               :recently_added,
               :recently_added_movies,
               :recently_added_tv,
               :trending_movies,
               :trending_tv,
               :episodes
             ]
    end
  end

  describe "available/1" do
    test "admin sees all widgets including system_health" do
      admin = %User{role: "admin"}
      keys = admin |> HomeLayout.available() |> Enum.map(& &1.key)

      assert :system_health in keys
      assert length(keys) == 9
    end

    test "non-admin roles do not see system_health" do
      for role <- ["user", "readonly", "guest"] do
        user = %User{role: role}
        keys = user |> HomeLayout.available() |> Enum.map(& &1.key)

        refute :system_health in keys
        assert length(keys) == 8
      end
    end

    test "accepts raw role strings" do
      assert :system_health in (HomeLayout.available("admin") |> Enum.map(& &1.key))
      refute :system_health in (HomeLayout.available("guest") |> Enum.map(& &1.key))
    end
  end

  describe "default_keys/1" do
    test "returns default keys for admin" do
      admin = %User{role: "admin"}

      assert HomeLayout.default_keys(admin) == [
               :library_stats,
               :system_health,
               :quick_actions,
               :recently_added,
               :trending_movies,
               :trending_tv,
               :episodes
             ]
    end

    test "returns default keys for non-admin" do
      user = %User{role: "user"}

      assert HomeLayout.default_keys(user) == [
               :library_stats,
               :quick_actions,
               :recently_added,
               :trending_movies,
               :trending_tv,
               :episodes
             ]
    end
  end

  describe "resolve/2" do
    test "returns default keys when stored is nil or not a list" do
      admin = %User{role: "admin"}

      assert HomeLayout.resolve(admin, nil) == HomeLayout.default_keys(admin)
      assert HomeLayout.resolve(admin, "invalid") == HomeLayout.default_keys(admin)
      assert HomeLayout.resolve(admin, 123) == HomeLayout.default_keys(admin)
    end

    test "empty list stays empty (user hid everything)" do
      admin = %User{role: "admin"}
      assert HomeLayout.resolve(admin, []) == []
    end

    test "filters out unknown keys and duplicates while preserving order" do
      user = %User{role: "user"}

      stored = [
        "trending_movies",
        "unknown_widget",
        "library_stats",
        "trending_movies",
        "episodes"
      ]

      assert HomeLayout.resolve(user, stored) == [
               :trending_movies,
               :library_stats,
               :episodes
             ]
    end

    test "drops role-forbidden keys for demoted users" do
      user = %User{role: "user"}
      stored = ["system_health", "library_stats", "trending_tv"]

      assert HomeLayout.resolve(user, stored) == [
               :library_stats,
               :trending_tv
             ]
    end

    test "accepts atom lists as well as string lists" do
      user = %User{role: "user"}

      assert HomeLayout.resolve(user, [:trending_tv, :library_stats]) == [
               :trending_tv,
               :library_stats
             ]
    end
  end

  describe "hidden/2" do
    test "returns available keys not in visible in catalog order" do
      admin = %User{role: "admin"}
      visible = [:library_stats, :trending_movies]

      assert HomeLayout.hidden(admin, visible) == [
               :system_health,
               :quick_actions,
               :recently_added,
               :recently_added_movies,
               :recently_added_tv,
               :trending_tv,
               :episodes
             ]
    end
  end

  describe "toggle/2" do
    test "removes key if already present" do
      assert HomeLayout.toggle([:library_stats, :quick_actions], :library_stats) == [
               :quick_actions
             ]

      assert HomeLayout.toggle([:library_stats, :quick_actions], "library_stats") == [
               :quick_actions
             ]
    end

    test "appends key if not present" do
      assert HomeLayout.toggle([:library_stats], :quick_actions) == [
               :library_stats,
               :quick_actions
             ]

      assert HomeLayout.toggle([:library_stats], "quick_actions") == [
               :library_stats,
               :quick_actions
             ]
    end

    test "ignores unknown key" do
      assert HomeLayout.toggle([:library_stats], "unknown") == [:library_stats]
    end
  end

  describe "move/3" do
    test "moves key up" do
      list = [:library_stats, :quick_actions, :episodes]

      assert HomeLayout.move(list, :quick_actions, :up) == [
               :quick_actions,
               :library_stats,
               :episodes
             ]
    end

    test "moves key down" do
      list = [:library_stats, :quick_actions, :episodes]

      assert HomeLayout.move(list, :quick_actions, :down) == [
               :library_stats,
               :episodes,
               :quick_actions
             ]
    end

    test "no-op at boundaries" do
      list = [:library_stats, :quick_actions, :episodes]
      assert HomeLayout.move(list, :library_stats, :up) == list
      assert HomeLayout.move(list, :episodes, :down) == list
    end

    test "no-op for hidden or unknown key" do
      list = [:library_stats, :quick_actions]
      assert HomeLayout.move(list, :system_health, :up) == list
      assert HomeLayout.move(list, "unknown", :down) == list
    end
  end
end
