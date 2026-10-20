defmodule Mydia.Accounts.ThemePreferenceTest do
  use Mydia.DataCase, async: true

  import Mydia.AccountsFixtures

  alias Mydia.Accounts
  alias Mydia.Accounts.UserPreference
  alias Mydia.Repo

  test "a new user resolves to the default selection" do
    pref = user_fixture() |> Accounts.get_user_preference!()
    assert UserPreference.theme_selection(pref) == Mydia.Accounts.Themes.default_selection()
  end

  test "stores a theme per slot alongside the mode" do
    pref = user_fixture() |> Accounts.get_user_preference!()

    {:ok, pref} =
      Accounts.update_preference(pref, %{
        "theme" => "dark",
        "light_theme" => "nord",
        "dark_theme" => "dracula"
      })

    selection = UserPreference.theme_selection(pref)
    assert selection.mode == "dark"
    assert selection.light.id == "nord"
    assert selection.dark.id == "dracula"
  end

  test "accepts every radius id and reads it into the selection" do
    pref = user_fixture() |> Accounts.get_user_preference!()
    assert UserPreference.theme_selection(pref).radius == "theme"

    for radius <- Mydia.Accounts.Themes.radii() do
      assert {:ok, pref} = Accounts.update_preference(pref, %{"radius" => radius})
      assert UserPreference.theme_selection(pref).radius == radius
    end
  end

  test "rejects an unknown radius" do
    pref = user_fixture() |> Accounts.get_user_preference!()

    assert {:error, changeset} = Accounts.update_preference(pref, %{"radius" => "pointy"})
    assert %{preferences: [_ | _]} = errors_on(changeset)
  end

  test "rejects a theme in the wrong slot and unknown ids" do
    pref = user_fixture() |> Accounts.get_user_preference!()

    for delta <- [
          %{"light_theme" => "dracula"},
          %{"dark_theme" => "nord"},
          %{"dark_theme" => "not-a-theme"},
          %{"theme" => "sepia"}
        ] do
      assert {:error, changeset} = Accounts.update_preference(pref, delta)
      assert %{preferences: [_ | _]} = errors_on(changeset)
    end
  end

  test "a stale stored slot does not block an unrelated save" do
    pref = user_fixture() |> Accounts.get_user_preference!()

    pref =
      pref
      |> Ecto.Changeset.change(preferences: Map.put(pref.preferences, "dark_theme", "retired"))
      |> Repo.update!()

    assert {:ok, pref} = Accounts.update_preference(pref, %{"theme" => "light"})
    assert UserPreference.theme_selection(pref).dark.id == "mydia-dark"
  end

  test "a stale stored radius does not block an unrelated save" do
    pref = user_fixture() |> Accounts.get_user_preference!()

    pref =
      pref
      |> Ecto.Changeset.change(preferences: Map.put(pref.preferences, "radius", "retired"))
      |> Repo.update!()

    assert {:ok, pref} = Accounts.update_preference(pref, %{"theme" => "light"})
    assert UserPreference.theme_selection(pref).radius == "theme"
  end
end
