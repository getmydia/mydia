defmodule Mydia.Accounts.ClaimUsernameTest do
  use Mydia.DataCase, async: true

  alias Mydia.Accounts.User

  describe "username_changeset/2" do
    test "writes a username and its source onto an account with neither" do
      changeset = User.username_changeset(%User{}, %{username: "robin", username_source: "email"})

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :username) == "robin"
      assert Ecto.Changeset.get_change(changeset, :username_source) == "email"
    end

    test "requires a username" do
      changeset = User.username_changeset(%User{}, %{username_source: "email"})

      refute changeset.valid?
      assert %{username: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects a username outside three to fifty characters" do
      refute User.username_changeset(%User{}, %{username: "ab"}).valid?
      refute User.username_changeset(%User{}, %{username: String.duplicate("a", 51)}).valid?
      assert User.username_changeset(%User{}, %{username: "abc"}).valid?
    end

    test "does not touch fields outside its two" do
      changeset =
        User.username_changeset(%User{role: "user"}, %{username: "robin", role: "admin"})

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :role) == nil
    end
  end
end
