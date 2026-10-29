defmodule Mydia.Accounts.LibraryListingPreferenceTest do
  use Mydia.DataCase, async: true

  import Mydia.AccountsFixtures

  alias Mydia.Accounts

  test "nothing stored reads as an empty state" do
    assert Accounts.library_listing_state(user_fixture(), "movies") == %{}
  end

  test "round-trips one page's state" do
    user = user_fixture()

    assert :ok =
             Accounts.put_library_listing_state(user, "movies", %{
               "sort" => "added_desc",
               "progress" => "missing"
             })

    assert Accounts.library_listing_state(user, "movies") ==
             %{"sort" => "added_desc", "progress" => "missing"}
  end

  test "pages are independent" do
    user = user_fixture()

    :ok = Accounts.put_library_listing_state(user, "movies", %{"sort" => "year_desc"})
    :ok = Accounts.put_library_listing_state(user, "tv_shows", %{"quality" => "2160p"})
    :ok = Accounts.put_library_listing_state(user, "movies", %{"sort" => "added_desc"})

    assert Accounts.library_listing_state(user, "movies") == %{"sort" => "added_desc"}
    assert Accounts.library_listing_state(user, "tv_shows") == %{"quality" => "2160p"}
  end

  test "an empty state is stored and read back as empty" do
    user = user_fixture()

    :ok = Accounts.put_library_listing_state(user, "movies", %{"sort" => "year_desc"})
    :ok = Accounts.put_library_listing_state(user, "movies", %{})

    assert Accounts.library_listing_state(user, "movies") == %{}
  end

  test "other preferences survive" do
    user = user_fixture()
    pref = Accounts.get_user_preference!(user)
    {:ok, _} = Accounts.update_preference(pref, %{"theme" => "dark"})

    :ok = Accounts.put_library_listing_state(user, "movies", %{"sort" => "year_desc"})

    assert Accounts.get_user_preference!(user).preferences["theme"] == "dark"
  end

  test "malformed stored data reads as empty" do
    user = user_fixture()
    pref = Accounts.get_user_preference!(user)

    pref
    |> Ecto.Changeset.change(preferences: Map.put(pref.preferences, "library_listing", "junk"))
    |> Mydia.Repo.update!()

    assert Accounts.library_listing_state(user, "movies") == %{}

    pref = Accounts.get_user_preference!(user)

    pref
    |> Ecto.Changeset.change(
      preferences: Map.put(pref.preferences, "library_listing", %{"movies" => %{"sort" => 3}})
    )
    |> Mydia.Repo.update!()

    assert Accounts.library_listing_state(user, "movies") == %{}
  end

  test "rejects a malformed library_listing write" do
    user = user_fixture()
    pref = Accounts.get_user_preference!(user)

    assert {:error, changeset} =
             Accounts.update_preference(pref, %{"library_listing" => %{"movies" => "junk"}})

    assert %{preferences: [_ | _]} = errors_on(changeset)
  end
end
