defmodule Mydia.Accounts.GridDensityPreferenceTest do
  use Mydia.DataCase, async: true

  import Mydia.AccountsFixtures

  alias Mydia.Accounts
  alias Mydia.Accounts.UserPreference

  test "defaults to comfortable" do
    user = user_fixture()
    pref = Accounts.get_user_preference!(user)

    assert UserPreference.grid_density(pref) == "comfortable"
  end

  test "persists a valid density via update_preference/2" do
    user = user_fixture()
    pref = Accounts.get_user_preference!(user)

    {:ok, _} = Accounts.update_preference(pref, %{"grid_density" => "dense"})

    reloaded = Accounts.get_user_preference!(user)
    assert UserPreference.grid_density(reloaded) == "dense"
  end

  test "rejects an unknown density" do
    user = user_fixture()
    pref = Accounts.get_user_preference!(user)

    assert {:error, changeset} = Accounts.update_preference(pref, %{"grid_density" => "tiny"})

    assert %{preferences: [_ | _]} = errors_on(changeset)
  end

  test "leaves other preferences intact when density changes" do
    user = user_fixture()
    pref = Accounts.get_user_preference!(user)

    {:ok, pref} = Accounts.update_preference(pref, %{"theme" => "dark"})
    {:ok, _} = Accounts.update_preference(pref, %{"grid_density" => "compact"})

    reloaded = Accounts.get_user_preference!(user)
    assert UserPreference.theme(reloaded) == "dark"
    assert UserPreference.grid_density(reloaded) == "compact"
  end
end
