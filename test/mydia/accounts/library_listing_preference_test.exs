defmodule Mydia.Accounts.LibraryListingPreferenceTest do
  use Mydia.DataCase, async: true

  import Mydia.AccountsFixtures

  alias Mydia.Accounts
  alias Mydia.Accounts.LibraryListingState

  test "nothing stored reads as an empty state" do
    assert LibraryListingState.get(user_fixture(), "movies") == %{}
  end

  test "round-trips one page's state" do
    user = user_fixture()

    assert :ok =
             LibraryListingState.put(user, "movies", %{
               "sort" => "added_desc",
               "progress" => "missing"
             })

    assert LibraryListingState.get(user, "movies") ==
             %{"sort" => "added_desc", "progress" => "missing"}
  end

  test "pages are independent" do
    user = user_fixture()

    :ok = LibraryListingState.put(user, "movies", %{"sort" => "year_desc"})
    :ok = LibraryListingState.put(user, "tv_shows", %{"quality" => "2160p"})
    :ok = LibraryListingState.put(user, "movies", %{"sort" => "added_desc"})

    assert LibraryListingState.get(user, "movies") == %{"sort" => "added_desc"}
    assert LibraryListingState.get(user, "tv_shows") == %{"quality" => "2160p"}
  end

  test "an empty state is stored and read back as empty" do
    user = user_fixture()

    :ok = LibraryListingState.put(user, "movies", %{"sort" => "year_desc"})
    :ok = LibraryListingState.put(user, "movies", %{})

    assert LibraryListingState.get(user, "movies") == %{}
  end

  test "other preferences survive" do
    user = user_fixture()
    pref = Accounts.get_user_preference!(user)
    {:ok, _} = Accounts.update_preference(pref, %{"theme" => "dark"})

    :ok = LibraryListingState.put(user, "movies", %{"sort" => "year_desc"})

    assert Accounts.get_user_preference!(user).preferences["theme"] == "dark"
  end

  test "malformed stored data reads as empty" do
    user = user_fixture()
    pref = Accounts.get_user_preference!(user)

    pref
    |> Ecto.Changeset.change(preferences: Map.put(pref.preferences, "library_listing", "junk"))
    |> Mydia.Repo.update!()

    assert LibraryListingState.get(user, "movies") == %{}

    pref = Accounts.get_user_preference!(user)

    pref
    |> Ecto.Changeset.change(
      preferences: Map.put(pref.preferences, "library_listing", %{"movies" => %{"sort" => 3}})
    )
    |> Mydia.Repo.update!()

    assert LibraryListingState.get(user, "movies") == %{}
  end

  describe "a malformed sibling entry" do
    setup do
      user = user_fixture()
      pref = Accounts.get_user_preference!(user)

      listing = %{"movies" => %{"sort" => "year_desc"}, "tv_shows" => "junk"}

      pref
      |> Ecto.Changeset.change(preferences: Map.put(pref.preferences, "library_listing", listing))
      |> Mydia.Repo.update!()

      %{user: user}
    end

    test "does not hide a valid page", %{user: user} do
      assert LibraryListingState.get(user, "movies") == %{"sort" => "year_desc"}
    end

    test "is dropped by the next save", %{user: user} do
      assert :ok = LibraryListingState.put(user, "movies", %{"sort" => "added_desc"})

      assert Accounts.get_user_preference!(user).preferences["library_listing"] ==
               %{"movies" => %{"sort" => "added_desc"}}
    end
  end

  test "rejects a malformed library_listing write" do
    user = user_fixture()
    pref = Accounts.get_user_preference!(user)

    assert {:error, changeset} =
             Accounts.update_preference(pref, %{"library_listing" => %{"movies" => "junk"}})

    assert %{preferences: [_ | _]} = errors_on(changeset)
  end
end
