defmodule Mydia.Accounts.ClaimUsernameTest do
  use Mydia.DataCase, async: true

  import Mydia.AccountsFixtures

  alias Mydia.Accounts
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

  describe "claim_username/2" do
    test "takes a free name as-is and records the tier" do
      user = user_fixture(%{username: "someone-else"})

      assert {:ok, claimed} = Accounts.claim_username(user, {:idp, "robin"})
      assert claimed.username == "robin"
      assert claimed.username_source == "idp"
    end

    test "suffixes past a name that is taken" do
      _taken = user_fixture(%{username: "robin"})
      user = user_fixture(%{username: "someone-else"})

      assert {:ok, claimed} = Accounts.claim_username(user, {:email, "robin"})
      assert claimed.username == "robin-2"
      assert claimed.username_source == "email"
    end

    test "walks forward over a run of taken suffixes" do
      _taken = user_fixture(%{username: "robin"})
      _taken_2 = user_fixture(%{username: "robin-2"})
      _taken_3 = user_fixture(%{username: "robin-3"})
      user = user_fixture(%{username: "someone-else"})

      assert {:ok, claimed} = Accounts.claim_username(user, {:email, "robin"})
      assert claimed.username == "robin-4"
    end

    test "returns :none rather than raising when the name cannot be validated" do
      user = user_fixture(%{username: "someone-else"})

      assert Accounts.claim_username(user, {:idp, "ab"}) == :none
      assert Mydia.Repo.reload(user).username == "someone-else"
    end
  end
end
