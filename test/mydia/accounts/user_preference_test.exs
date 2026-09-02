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

  describe "update_preference/2 optimistic locking" do
    test "retries a stale update against fresh preferences" do
      user = user_fixture()
      first_session = Accounts.get_user_preference!(user)
      second_session = Accounts.get_user_preference!(user)

      assert {:ok, first_update} =
               Accounts.update_preference(first_session, %{"grid_density" => "dense"})

      assert {:ok, retried_update} =
               Accounts.update_preference(second_session, %{"recommendations_expanded" => true})

      assert UserPreference.grid_density(retried_update) == "dense"
      assert UserPreference.recommendations_expanded(retried_update)
      assert retried_update.lock_version == first_update.lock_version + 1

      assert {:ok, retained_update} =
               Accounts.update_preference(retried_update, %{"theme" => "dark"})

      assert UserPreference.grid_density(retained_update) == "dense"
      assert UserPreference.recommendations_expanded(retained_update)
      assert UserPreference.theme(retained_update) == "dark"
      assert retained_update.lock_version == retried_update.lock_version + 1

      persisted = Repo.get!(UserPreference, retained_update.id)
      assert persisted.preferences == retained_update.preferences
      assert persisted.lock_version == retained_update.lock_version
    end

    test "flat and nested deltas preserve unrelated preferences" do
      user = user_fixture()
      preference = Accounts.get_user_preference!(user)

      assert {:ok, preference} =
               Accounts.update_preference(preference, %{"theme" => "dark"})

      assert {:ok, preference} =
               Accounts.update_preference(preference, %{
                 "preferences" => %{"grid_density" => "compact"}
               })

      assert UserPreference.theme(preference) == "dark"
      assert UserPreference.grid_density(preference) == "compact"
      assert UserPreference.metadata_language(preference) == "en"
    end

    test "invalid preference values are not treated as lock conflicts" do
      user = user_fixture()
      preference = Accounts.get_user_preference!(user)

      assert {:error, changeset} =
               Accounts.update_preference(preference, %{"grid_density" => "tiny"})

      refute changeset.valid?
      refute Keyword.has_key?(changeset.errors, :lock_version)
      assert Repo.reload!(preference).lock_version == preference.lock_version
    end

    test "invalid reference ids are not treated as lock conflicts" do
      user = user_fixture()
      preference = Accounts.get_user_preference!(user)

      assert {:error, changeset} =
               Accounts.update_preference(preference, %{
                 "add_quality_profile_id" => Ecto.UUID.generate()
               })

      refute changeset.valid?
      refute Keyword.has_key?(changeset.errors, :lock_version)
      assert Repo.reload!(preference).lock_version == preference.lock_version
    end

    test "returns a stale changeset after exhausting retries" do
      user = user_fixture()
      stale_preference = Accounts.get_user_preference!(user)

      assert {:ok, _updated} =
               Accounts.update_preference(stale_preference, %{"theme" => "dark"})

      test_pid = self()
      {:ok, conflict_count} = Agent.start_link(fn -> 0 end)
      handler_id = {__MODULE__, :preference_retry_conflicts, test_pid}

      :telemetry.attach(
        handler_id,
        [:mydia, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          query = String.trim_leading(metadata.query)

          if Process.get(:force_preference_retry_conflicts, false) and
               metadata.source == "user_preferences" and String.starts_with?(query, "SELECT") do
            Repo.update_all(
              from(p in UserPreference, where: p.id == ^stale_preference.id),
              inc: [lock_version: 1]
            )

            Agent.update(conflict_count, &(&1 + 1))
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      task =
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Repo, test_pid, self())
          Process.put(:force_preference_retry_conflicts, true)
          Accounts.update_preference(stale_preference, %{"grid_density" => "dense"})
        end)

      assert {:error, changeset} = Task.await(task, 5_000)
      assert Keyword.has_key?(changeset.errors, :lock_version)
      assert Agent.get(conflict_count, & &1) > 1
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
