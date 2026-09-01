defmodule Mydia.Accounts.PlayerVisibilityPreferenceTest do
  use Mydia.DataCase, async: true

  import Mydia.AccountsFixtures

  alias Mydia.Accounts
  alias Mydia.Accounts.UserPreference

  test "both keys default to false" do
    user = user_fixture()
    pref = Accounts.get_user_preference!(user)

    refute UserPreference.hide_player?(pref)
    refute UserPreference.player_banner_dismissed?(pref)
  end

  test "defaults to false for a row that predates the keys" do
    user = user_fixture()

    legacy =
      user
      |> Accounts.get_user_preference!()
      |> Ecto.Changeset.change(preferences: %{"theme" => "dark"})
      |> Repo.update!()

    refute UserPreference.hide_player?(legacy)
    refute UserPreference.player_banner_dismissed?(legacy)
  end

  test "dismiss_player_banner/1 sets the key" do
    user = user_fixture()

    {:ok, _} = Accounts.dismiss_player_banner(user)

    assert UserPreference.player_banner_dismissed?(Accounts.get_user_preference!(user))
  end

  test "dismiss_player_banner/1 is idempotent" do
    user = user_fixture()

    {:ok, _} = Accounts.dismiss_player_banner(user)
    {:ok, _} = Accounts.dismiss_player_banner(user)

    assert UserPreference.player_banner_dismissed?(Accounts.get_user_preference!(user))
  end

  test "hide_player persists via update_preference/2" do
    user = user_fixture()
    pref = Accounts.get_user_preference!(user)

    {:ok, _} = Accounts.update_preference(pref, %{"hide_player" => true})

    assert UserPreference.hide_player?(Accounts.get_user_preference!(user))
  end

  test "rejects a non-boolean for either key" do
    user = user_fixture()
    pref = Accounts.get_user_preference!(user)

    assert {:error, hide_changeset} = Accounts.update_preference(pref, %{"hide_player" => "yes"})
    assert %{preferences: [_ | _]} = errors_on(hide_changeset)

    assert {:error, dismiss_changeset} =
             Accounts.update_preference(pref, %{"player_banner_dismissed" => "yes"})

    assert %{preferences: [_ | _]} = errors_on(dismiss_changeset)
  end

  test "a stored string reads back as false" do
    user = user_fixture()

    corrupted =
      user
      |> Accounts.get_user_preference!()
      |> Ecto.Changeset.change(
        preferences: %{"hide_player" => "true", "player_banner_dismissed" => "true"}
      )
      |> Repo.update!()

    refute UserPreference.hide_player?(corrupted)
    refute UserPreference.player_banner_dismissed?(corrupted)
  end

  test "leaves other preferences intact" do
    user = user_fixture()
    pref = Accounts.get_user_preference!(user)

    {:ok, pref} = Accounts.update_preference(pref, %{"theme" => "dark"})
    {:ok, _} = Accounts.update_preference(pref, %{"hide_player" => true})

    reloaded = Accounts.get_user_preference!(user)
    assert UserPreference.theme(reloaded) == "dark"
    assert UserPreference.hide_player?(reloaded)
  end
end
