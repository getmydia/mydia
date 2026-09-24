defmodule Mydia.Accounts.PosterFieldsPreferenceTest do
  use Mydia.DataCase, async: true

  import Mydia.AccountsFixtures

  alias Mydia.Accounts
  alias Mydia.Accounts.PosterFields
  alias Mydia.Accounts.UserPreference

  test "defaults when never set" do
    pref = user_fixture() |> Accounts.get_user_preference!()
    assert UserPreference.poster_fields(pref) == PosterFields.default_keys()
  end

  test "persists a valid list, including an empty one" do
    user = user_fixture()
    pref = Accounts.get_user_preference!(user)

    {:ok, pref} = Accounts.update_preference(pref, %{"poster_fields" => ["year", "show_status"]})
    assert UserPreference.poster_fields(pref) == [:year, :show_status]

    {:ok, _} = Accounts.update_preference(pref, %{"poster_fields" => []})
    assert user |> Accounts.get_user_preference!() |> UserPreference.poster_fields() == []
  end

  test "rejects unknown keys, duplicates and non-lists" do
    pref = user_fixture() |> Accounts.get_user_preference!()

    for bad <- [["year", "bogus"], ["year", "year"], "year", [1]] do
      assert {:error, changeset} = Accounts.update_preference(pref, %{"poster_fields" => bad})
      assert %{preferences: [_ | _]} = errors_on(changeset)
    end
  end

  test "a stale stored key is ignored on read" do
    pref = %UserPreference{preferences: %{"poster_fields" => ["year", "retired_field"]}}
    assert UserPreference.poster_fields(pref) == [:year]
  end
end
