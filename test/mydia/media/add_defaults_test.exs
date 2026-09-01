defmodule Mydia.Media.AddDefaultsTest do
  use Mydia.DataCase, async: false

  import Mydia.AccountsFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Accounts
  alias Mydia.Config.Schema
  alias Mydia.Media.AddDefaults

  defp config(overrides) do
    base = Schema.defaults()
    %{base | media: struct(base.media, overrides)}
  end

  describe "layer 4: hard fallbacks" do
    test "resolves with no user, no settings and a bare config" do
      defaults = AddDefaults.resolve(nil, :movie, config: config(%{}))

      assert defaults.monitored == true
      assert defaults.season_monitoring == "all"
      assert defaults.search_on_add == true
    end
  end

  describe "layer 3: instance settings" do
    test "reads monitored, season monitoring and search on add from config" do
      cfg =
        config(%{
          monitor_by_default: false,
          default_season_monitoring: "first",
          auto_search_on_add: false
        })

      defaults = AddDefaults.resolve(nil, :tv_show, config: cfg)

      assert defaults.monitored == false
      assert defaults.season_monitoring == "first"
      assert defaults.search_on_add == false
    end

    test "reads the quality profile from the instance default" do
      profile = quality_profile_fixture()
      Mydia.Settings.set_default_quality_profile(profile.id)

      defaults = AddDefaults.resolve(nil, :movie, config: config(%{}))

      assert defaults.quality_profile_id == profile.id
    end

    test "reads the library path from the per-kind default" do
      library = library_path_fixture(%{type: :movies})
      Mydia.Settings.set_default_library(library, :movies)

      defaults = AddDefaults.resolve(nil, :movie, config: config(%{}))

      assert defaults.library_path_id == library.id
    end
  end

  describe "layer 2: user preferences" do
    test "a user preference beats the instance setting" do
      user = user_fixture()
      pref = Accounts.get_user_preference!(user)

      {:ok, _} =
        Accounts.update_preference(pref, %{
          "preferences" => %{"add_monitored" => false, "add_season_monitoring" => "none"}
        })

      user = Accounts.get_user!(user.id)

      defaults =
        AddDefaults.resolve(user, :tv_show,
          config: config(%{monitor_by_default: true, default_season_monitoring: "all"})
        )

      assert defaults.monitored == false
      assert defaults.season_monitoring == "none"
    end

    test "an unset user preference falls through to the instance setting" do
      user = user_fixture()

      defaults =
        AddDefaults.resolve(user, :movie, config: config(%{monitor_by_default: false}))

      assert defaults.monitored == false
    end
  end

  describe "layer 1: explicit opts" do
    test "an explicit opt beats a user preference" do
      user = user_fixture()
      pref = Accounts.get_user_preference!(user)
      {:ok, _} = Accounts.update_preference(pref, %{"preferences" => %{"add_monitored" => false}})
      user = Accounts.get_user!(user.id)

      defaults = AddDefaults.resolve(user, :movie, monitored: true, config: config(%{}))

      assert defaults.monitored == true
    end

    test "an explicit library path beats everything" do
      library = library_path_fixture(%{type: :movies})
      Mydia.Settings.set_default_library(library, :movies)
      other = library_path_fixture(%{type: :movies})

      defaults =
        AddDefaults.resolve(nil, :movie, library_path_id: other.id, config: config(%{}))

      assert defaults.library_path_id == other.id
    end
  end

  describe "stale references" do
    test "a deleted quality profile falls back to the instance default" do
      instance_profile = quality_profile_fixture()
      Mydia.Settings.set_default_quality_profile(instance_profile.id)

      user = user_fixture()
      pref = Accounts.get_user_preference!(user)

      stale_id = Ecto.UUID.generate()

      # Written directly rather than through update_preference/2, which would
      # reject it. This is the row-deleted-later case, not the bad-input case.
      {:ok, _} =
        pref
        |> Ecto.Changeset.change(preferences: %{"add_quality_profile_id" => stale_id})
        |> Mydia.Repo.update()

      user = Accounts.get_user!(user.id)

      defaults = AddDefaults.resolve(user, :movie, config: config(%{}))

      assert defaults.quality_profile_id == instance_profile.id
    end

    test "a library path whose type changed since it was saved falls back to the instance default" do
      instance_library = library_path_fixture(%{type: :movies})
      Mydia.Settings.set_default_library(instance_library, :movies)

      # This library was valid as a movie override when saved, but its type
      # changed to series-only later. Written directly rather than through
      # update_preference/2, which would reject a series-only library under
      # the movie key today.
      retyped_library = library_path_fixture(%{type: :series})

      user = user_fixture()
      pref = Accounts.get_user_preference!(user)

      {:ok, _} =
        pref
        |> Ecto.Changeset.change(
          preferences: %{"add_movie_library_path_id" => retyped_library.id}
        )
        |> Mydia.Repo.update()

      user = Accounts.get_user!(user.id)

      defaults = AddDefaults.resolve(user, :movie, config: config(%{}))

      assert defaults.library_path_id == instance_library.id
    end
  end

  describe "to_add_opts/1" do
    test "returns the four Media.Add options and omits search_on_add" do
      defaults = AddDefaults.resolve(nil, :movie, config: config(%{}))
      opts = AddDefaults.to_add_opts(defaults)

      assert Keyword.has_key?(opts, :monitored)
      assert Keyword.has_key?(opts, :season_monitoring)
      assert Keyword.has_key?(opts, :library_path_id)
      assert Keyword.has_key?(opts, :quality_profile_id)
      refute Keyword.has_key?(opts, :search_on_add)
    end
  end
end
