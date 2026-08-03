defmodule Mydia.Accounts.ChangelogPreferenceTest do
  use Mydia.DataCase, async: true

  alias Mydia.Accounts

  defp user_fixture do
    unique_id = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.create_user(%{
        email: "changelog_#{unique_id}@example.com",
        username: "changelog_#{unique_id}",
        password_hash: "$2b$12$test",
        role: "user"
      })

    user
  end

  describe "last_seen_changelog_version/1" do
    test "is nil for a user who has never seen the changelog" do
      assert Accounts.last_seen_changelog_version(user_fixture()) == nil
    end

    test "creates the preferences row lazily rather than raising" do
      user = user_fixture()
      assert Accounts.last_seen_changelog_version(user) == nil
      assert Accounts.get_user_preference!(user)
    end

    test "returns what was stored" do
      user = user_fixture()
      {:ok, _} = Accounts.mark_changelog_seen(user, "0.12.0")
      assert Accounts.last_seen_changelog_version(user) == "0.12.0"
    end
  end

  describe "mark_changelog_seen/2" do
    test "moves the stored version forward" do
      user = user_fixture()
      {:ok, _} = Accounts.mark_changelog_seen(user, "0.12.0")
      {:ok, _} = Accounts.mark_changelog_seen(user, "0.13.0")
      assert Accounts.last_seen_changelog_version(user) == "0.13.0"
    end

    test "refuses to move the stored version backward" do
      user = user_fixture()
      {:ok, _} = Accounts.mark_changelog_seen(user, "0.13.0")
      {:ok, _} = Accounts.mark_changelog_seen(user, "0.12.0")
      assert Accounts.last_seen_changelog_version(user) == "0.13.0"
    end

    test "is a no-op when the same version is written twice" do
      user = user_fixture()
      {:ok, _} = Accounts.mark_changelog_seen(user, "0.13.0")
      {:ok, _} = Accounts.mark_changelog_seen(user, "0.13.0")
      assert Accounts.last_seen_changelog_version(user) == "0.13.0"
    end

    test "overwrites an unparseable stored value" do
      user = user_fixture()
      pref = Accounts.get_user_preference!(user)
      {:ok, _} = Accounts.update_preference(pref, %{"last_seen_changelog_version" => "garbage"})

      {:ok, _} = Accounts.mark_changelog_seen(user, "0.13.0")
      assert Accounts.last_seen_changelog_version(user) == "0.13.0"
    end

    test "preserves unrelated preferences" do
      user = user_fixture()
      pref = Accounts.get_user_preference!(user)
      {:ok, _} = Accounts.update_preference(pref, %{"theme" => "dark"})

      {:ok, _} = Accounts.mark_changelog_seen(user, "0.13.0")

      preferences = Accounts.get_user_preference!(user).preferences
      assert preferences["theme"] == "dark"
      assert preferences["last_seen_changelog_version"] == "0.13.0"
    end
  end
end
