defmodule Mydia.Accounts.HomeWidgetsPreferenceTest do
  use Mydia.DataCase, async: true

  import Mydia.AccountsFixtures

  alias Mydia.Accounts
  alias Mydia.Accounts.HomeLayout

  test "home_widgets/1 returns default keys when unset" do
    user = user_fixture(%{role: "admin"})
    assert Accounts.home_widgets(user) == HomeLayout.default_keys(user)

    guest = user_fixture(%{role: "guest"})
    assert Accounts.home_widgets(guest) == HomeLayout.default_keys(guest)
  end

  test "home_widgets/1 returns default keys for nil (guest)" do
    assert Accounts.home_widgets(nil) == HomeLayout.default_keys("guest")
  end

  test "put_home_widgets/2 stores widget list and returns updated preference" do
    user = user_fixture(%{role: "user"})

    {:ok, _} = Accounts.put_home_widgets(user, [:trending_tv, :library_stats])

    assert Accounts.home_widgets(user) == [:trending_tv, :library_stats]
    pref = Accounts.get_user_preference!(user)
    assert pref.preferences["home_widgets"] == ["trending_tv", "library_stats"]
  end

  test "reset_home_widgets/1 removes the key and preserves other preferences" do
    user = user_fixture(%{role: "user"})
    pref = Accounts.get_user_preference!(user)
    {:ok, _} = Accounts.update_preference(pref, %{"theme" => "dark"})

    {:ok, _} = Accounts.put_home_widgets(user, [:trending_tv])
    assert Accounts.get_user_preference!(user).preferences["home_widgets"] == ["trending_tv"]

    {:ok, _} = Accounts.reset_home_widgets(user)
    reloaded = Accounts.get_user_preference!(user)

    refute Map.has_key?(reloaded.preferences, "home_widgets")
    assert reloaded.preferences["theme"] == "dark"
    assert Accounts.home_widgets(user) == HomeLayout.default_keys(user)
  end
end
