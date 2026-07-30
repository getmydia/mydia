defmodule Mydia.Accounts.CloseAfterGrabPreferenceTest do
  use Mydia.DataCase, async: true

  import Mydia.AccountsFixtures

  alias Mydia.Accounts
  alias Mydia.Accounts.UserPreference

  test "defaults to false" do
    user = user_fixture()
    pref = Accounts.get_user_preference!(user)

    refute UserPreference.close_manual_search_after_grab?(pref)
  end

  test "persists true via update_preference/2" do
    user = user_fixture()
    pref = Accounts.get_user_preference!(user)

    {:ok, _} = Accounts.update_preference(pref, %{"close_manual_search_after_grab" => true})

    reloaded = Accounts.get_user_preference!(user)
    assert UserPreference.close_manual_search_after_grab?(reloaded)
  end

  test "rejects non-boolean values" do
    user = user_fixture()
    pref = Accounts.get_user_preference!(user)

    assert {:error, changeset} =
             Accounts.update_preference(pref, %{"close_manual_search_after_grab" => "yes"})

    assert %{preferences: [_ | _]} = errors_on(changeset)
  end
end
