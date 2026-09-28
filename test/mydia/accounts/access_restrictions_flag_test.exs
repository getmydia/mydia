defmodule Mydia.Accounts.AccessRestrictionsFlagTest do
  @moduledoc """
  The "restrictions may exist" flag lets `Scope.for_user/1` skip one query per
  request on installs that never use restrictions. It must fail safe: an
  absent key means "look it up", and nothing but a boot-time recount may
  set it to false.
  """
  # :persistent_term is global and the sandbox does not roll it back.
  use Mydia.DataCase, async: false

  import Mydia.AccountsFixtures

  alias Mydia.Accounts
  alias Mydia.Accounts.AccessRestriction
  alias Mydia.Accounts.Scope
  alias Mydia.Repo

  @key {Mydia.Accounts, :access_restrictions?}

  setup do
    previous = :persistent_term.get(@key, :absent)
    :persistent_term.erase(@key)

    on_exit(fn ->
      case previous do
        :absent -> :persistent_term.erase(@key)
        value -> :persistent_term.put(@key, value)
      end
    end)

    :ok
  end

  # Inserts a row without going through upsert_access_restriction/2, so the
  # flag is left exactly as the test set it.
  defp insert_row(user) do
    Repo.insert!(%AccessRestriction{user_id: user.id, max_content_age: 7})
  end

  test "with the flag absent, for_user/1 reads the row" do
    user = user_fixture()
    insert_row(user)

    assert %Scope{max_content_age: 7} = Scope.for_user(user)
  end

  test "with the flag false, for_user/1 skips the lookup" do
    :persistent_term.put(@key, false)
    user = user_fixture()
    insert_row(user)

    refute Scope.restricted?(Scope.for_user(user))
  end

  test "an upsert flips the flag, and the next scope applies the row" do
    :persistent_term.put(@key, false)
    user = user_fixture()

    assert {:ok, _} = Accounts.upsert_access_restriction(user, %{max_content_age: 7})
    assert :persistent_term.get(@key) == true
    assert %Scope{max_content_age: 7} = Scope.for_user(user)
  end

  test "a refused upsert leaves the flag alone" do
    :persistent_term.put(@key, false)

    assert {:error, :admin} =
             Accounts.upsert_access_restriction(admin_user_fixture(), %{max_content_age: 7})

    assert :persistent_term.get(@key) == false
  end

  test "clearing a restriction never sets the flag back to false" do
    user = restricted_user_fixture(%{max_content_age: 7})

    assert :ok = Accounts.clear_access_restriction(user)
    assert :persistent_term.get(@key) == true
  end

  test "refresh derives the flag from the table" do
    assert :ok = Accounts.refresh_access_restrictions_flag()
    assert :persistent_term.get(@key) == false
    refute Accounts.access_restrictions_possible?()

    insert_row(user_fixture())

    assert :ok = Accounts.refresh_access_restrictions_flag()
    assert Accounts.access_restrictions_possible?()
  end

  test "an absent flag reads as possible" do
    assert Accounts.access_restrictions_possible?()
  end
end
