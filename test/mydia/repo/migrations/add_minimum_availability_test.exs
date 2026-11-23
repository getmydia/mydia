defmodule Mydia.Repo.Migrations.AddMinimumAvailabilityTest do
  use Mydia.DataCase, async: false

  import Mydia.MediaFixtures

  alias Mydia.Settings

  # Migration modules are not compiled into the app, so load the file before
  # referencing it. The upgrade step is exercised through
  # `keep_existing_behaviour/0` rather than Ecto.Migrator, which deadlocks
  # against the DataCase sandbox on PostgreSQL.
  unless Code.ensure_loaded?(Mydia.Repo.Migrations.AddMinimumAvailability) do
    Code.require_file("priv/repo/migrations/20261123155008_add_minimum_availability.exs")
  end

  alias Mydia.Repo.Migrations.AddMinimumAvailability

  @key "media.minimum_availability"

  test "an install that already has movies keeps searching them as before" do
    media_item_fixture(%{type: "movie", title: "Copper Weather"})

    AddMinimumAvailability.keep_existing_behaviour()

    assert Settings.get_config_setting_by_key(@key).value == "announced"
  end

  test "an install with only TV shows gets the new default" do
    media_item_fixture(%{type: "tv_show", title: "Copper Weather Stories"})

    AddMinimumAvailability.keep_existing_behaviour()

    assert Settings.get_config_setting_by_key(@key) == nil
  end

  test "a fresh install gets the new default" do
    AddMinimumAvailability.keep_existing_behaviour()

    assert Settings.get_config_setting_by_key(@key) == nil
  end
end
