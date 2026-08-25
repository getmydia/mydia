defmodule Mydia.Accounts.ScopeTest do
  use Mydia.DataCase, async: true

  import Mydia.AccountsFixtures

  alias Mydia.Accounts
  alias Mydia.Accounts.AccessRestriction
  alias Mydia.Accounts.Scope
  alias Mydia.Repo

  test "a user with no restriction row is unrestricted" do
    scope = Scope.for_user(user_fixture())

    assert scope.allowed_categories == nil
    assert scope.max_content_age == nil
    refute Scope.restricted?(scope)
  end

  test "a user with a restriction row carries it" do
    user = user_fixture()

    {:ok, _} =
      Accounts.upsert_access_restriction(user, %{
        allowed_categories: ["cartoon_movie", "cartoon_series"],
        max_content_age: 12
      })

    scope = Scope.for_user(user)

    assert scope.allowed_categories == ["cartoon_movie", "cartoon_series"]
    assert scope.max_content_age == 12
    assert Scope.restricted?(scope)
  end

  test "an admin is unrestricted even if a row somehow exists" do
    admin = admin_user_fixture()

    assert {:error, :admin} = Accounts.upsert_access_restriction(admin, %{max_content_age: 0})

    # upsert_access_restriction/2 refuses admins, so a stray row can only
    # reach the table some other way (a role change after the row was
    # created, a manual insert, a bug). Insert one directly to pin that
    # for_user/1 still ignores it for an admin regardless of how it got
    # there.
    %AccessRestriction{user_id: admin.id, max_content_age: 0}
    |> Repo.insert!()

    scope = Scope.for_user(admin)

    refute Scope.restricted?(scope)
  end

  test "an empty category list is not a restriction" do
    user = user_fixture()
    {:ok, _} = Accounts.upsert_access_restriction(user, %{allowed_categories: []})

    scope = Scope.for_user(user)

    assert scope.allowed_categories == nil
    refute Scope.restricted?(scope)
  end

  test "system and unrestricted scopes carry no limits" do
    refute Scope.restricted?(Scope.system())
    refute Scope.restricted?(Scope.unrestricted())
    assert Scope.system().user == nil
  end

  test "an unknown category is rejected rather than silently stored" do
    user = user_fixture()

    assert {:error, changeset} =
             Accounts.upsert_access_restriction(user, %{allowed_categories: ["documentary"]})

    assert "contains unknown categories: documentary" in errors_on(changeset).allowed_categories
  end

  test "an age outside the offered ladder is rejected" do
    user = user_fixture()

    assert {:error, changeset} =
             Accounts.upsert_access_restriction(user, %{max_content_age: 13})

    assert changeset.errors[:max_content_age]
  end

  test "clearing an existing restriction removes it and returns the user to unrestricted" do
    user = user_fixture()

    {:ok, _} = Accounts.upsert_access_restriction(user, %{max_content_age: 12})
    assert Accounts.get_access_restriction(user)

    assert :ok = Accounts.clear_access_restriction(user)

    assert Accounts.get_access_restriction(user) == nil
    refute Scope.restricted?(Scope.for_user(user))
  end

  test "clearing a restriction for a user who has none is a safe no-op" do
    user = user_fixture()

    assert Accounts.get_access_restriction(user) == nil
    assert :ok = Accounts.clear_access_restriction(user)
    assert Accounts.get_access_restriction(user) == nil
  end
end
