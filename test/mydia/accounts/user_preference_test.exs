defmodule Mydia.Accounts.UserPreferenceTest do
  use Mydia.DataCase, async: true

  import Mydia.AccountsFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Accounts
  alias Mydia.Accounts.UserPreference

  describe "add-option getters" do
    test "return nil when unset, meaning inherit" do
      pref = %UserPreference{preferences: %{}}

      assert UserPreference.add_library_path_id(pref, :movie) == nil
      assert UserPreference.add_library_path_id(pref, :tv_show) == nil
      assert UserPreference.add_quality_profile_id(pref) == nil
      assert UserPreference.add_monitored(pref) == nil
      assert UserPreference.add_season_monitoring(pref) == nil
      assert UserPreference.add_search_on_add(pref) == nil
    end

    test "read movie and series library paths from separate keys" do
      pref = %UserPreference{
        preferences: %{
          "add_movie_library_path_id" => "movie-lib",
          "add_series_library_path_id" => "series-lib"
        }
      }

      assert UserPreference.add_library_path_id(pref, :movie) == "movie-lib"
      assert UserPreference.add_library_path_id(pref, :tv_show) == "series-lib"
    end
  end

  describe "validation" do
    test "rejects an unsupported season monitoring value" do
      changeset =
        UserPreference.changeset(%UserPreference{}, %{
          preferences: %{"add_season_monitoring" => "sometimes"}
        })

      refute changeset.valid?
    end

    test "accepts every supported season monitoring value" do
      for value <- ["all", "first", "future", "none"] do
        changeset =
          UserPreference.changeset(%UserPreference{}, %{
            preferences: %{"add_season_monitoring" => value}
          })

        assert changeset.valid?, "expected #{value} to be accepted"
      end
    end

    test "rejects a non-boolean add_monitored" do
      changeset =
        UserPreference.changeset(%UserPreference{}, %{
          preferences: %{"add_monitored" => "yes"}
        })

      refute changeset.valid?
    end
  end

  describe "update_preference/2 reference validation" do
    test "rejects a quality profile id that does not exist" do
      user = user_fixture()
      pref = Accounts.get_user_preference!(user)

      assert {:error, changeset} =
               Accounts.update_preference(pref, %{
                 "preferences" => %{"add_quality_profile_id" => Ecto.UUID.generate()}
               })

      refute changeset.valid?
    end

    test "accepts a quality profile id that exists" do
      user = user_fixture()
      profile = quality_profile_fixture()
      pref = Accounts.get_user_preference!(user)

      assert {:ok, updated} =
               Accounts.update_preference(pref, %{
                 "preferences" => %{"add_quality_profile_id" => profile.id}
               })

      assert UserPreference.add_quality_profile_id(updated) == profile.id
    end

    test "does not re-validate a stale reference when saving an unrelated preference" do
      user = user_fixture()
      profile = quality_profile_fixture()
      pref = Accounts.get_user_preference!(user)

      {:ok, pref} =
        Accounts.update_preference(pref, %{
          "preferences" => %{"add_quality_profile_id" => profile.id}
        })

      # Simulate an admin deleting the profile out of band, after it was
      # already stored as a valid reference.
      Mydia.Repo.delete!(profile)

      assert {:ok, updated} = Accounts.update_preference(pref, %{"theme" => "dark"})
      assert UserPreference.theme(updated) == "dark"
      assert UserPreference.add_quality_profile_id(updated) == profile.id
    end

    test "rejects a malformed id instead of raising" do
      user = user_fixture()
      pref = Accounts.get_user_preference!(user)

      assert {:error, changeset} =
               Accounts.update_preference(pref, %{
                 "preferences" => %{"add_quality_profile_id" => "not-a-uuid"}
               })

      refute changeset.valid?
    end

    test "rejects a series-only library path stored as the movie override" do
      user = user_fixture()
      series_library = library_path_fixture(%{type: "series"})
      pref = Accounts.get_user_preference!(user)

      assert {:error, changeset} =
               Accounts.update_preference(pref, %{
                 "preferences" => %{"add_movie_library_path_id" => series_library.id}
               })

      refute changeset.valid?
    end

    test "accepts a mixed-type library path under either add-option key" do
      user = user_fixture()
      mixed_library = library_path_fixture(%{type: "mixed"})
      pref = Accounts.get_user_preference!(user)

      assert {:ok, pref} =
               Accounts.update_preference(pref, %{
                 "preferences" => %{"add_movie_library_path_id" => mixed_library.id}
               })

      assert UserPreference.add_library_path_id(pref, :movie) == mixed_library.id

      assert {:ok, pref} =
               Accounts.update_preference(pref, %{
                 "preferences" => %{"add_series_library_path_id" => mixed_library.id}
               })

      assert UserPreference.add_library_path_id(pref, :tv_show) == mixed_library.id
    end
  end
end
