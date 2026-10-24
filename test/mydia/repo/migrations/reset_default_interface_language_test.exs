defmodule Mydia.Repo.Migrations.ResetDefaultInterfaceLanguageTest do
  use Mydia.DataCase, async: false

  import Mydia.AccountsFixtures

  alias Mydia.Accounts
  alias Mydia.Accounts.UserPreference

  # Migration modules are not compiled into the app, so load the file before
  # referencing it. Guarded because the `test` alias may already have defined
  # the module while migrating this VM's database. The rewrite is exercised
  # through `reset/0` rather than Ecto.Migrator, which deadlocks against the
  # DataCase sandbox on PostgreSQL.
  unless Code.ensure_loaded?(Mydia.Repo.Migrations.ResetDefaultInterfaceLanguage) do
    Code.require_file("priv/repo/migrations/20261024164324_reset_default_interface_language.exs")
  end

  alias Mydia.Repo.Migrations.ResetDefaultInterfaceLanguage

  defp user_with_preferences(prefs) do
    user = user_fixture()

    user
    |> Accounts.get_user_preference!()
    |> Ecto.Changeset.change(preferences: prefs)
    |> Repo.update!()

    user
  end

  defp stored(user), do: Repo.get_by!(UserPreference, user_id: user.id).preferences

  test "drops a stored \"en\" so the user falls back to automatic" do
    user = user_with_preferences(%{"interface_language" => "en", "theme" => "dark"})

    ResetDefaultInterfaceLanguage.reset()

    assert stored(user) == %{"theme" => "dark"}
  end

  test "keeps a language other than en" do
    user = user_with_preferences(%{"interface_language" => "es", "theme" => "dark"})

    ResetDefaultInterfaceLanguage.reset()

    assert stored(user) == %{"interface_language" => "es", "theme" => "dark"}
  end

  test "leaves rows without the key untouched" do
    user = user_with_preferences(%{"theme" => "light"})

    ResetDefaultInterfaceLanguage.reset()

    assert stored(user) == %{"theme" => "light"}
  end
end
