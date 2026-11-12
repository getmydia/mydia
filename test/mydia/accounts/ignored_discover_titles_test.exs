defmodule Mydia.Accounts.IgnoredDiscoverTitlesTest do
  use Mydia.DataCase, async: true

  import Mydia.AccountsFixtures

  alias Mydia.Accounts
  alias Mydia.Accounts.{DiscoverIgnores, IgnoredDiscoverTitle}

  test "ignoring twice keeps one row" do
    user = user_fixture()

    assert :ok = DiscoverIgnores.ignore(user, {:tmdb, 101}, :movie)
    assert :ok = DiscoverIgnores.ignore(user, {:tmdb, 101}, :movie)

    assert Repo.aggregate(IgnoredDiscoverTitle, :count) == 1
  end

  test "unignoring a title that is not ignored is a no-op" do
    user = user_fixture()

    assert :ok = DiscoverIgnores.unignore(user, {:tmdb, 999}, :movie)
  end

  test "unignoring removes the key" do
    user = user_fixture()
    :ok = DiscoverIgnores.ignore(user, {:tmdb, 102}, :movie)

    assert :ok = DiscoverIgnores.unignore(user, {:tmdb, 102}, :movie)
    assert DiscoverIgnores.keys(user) == MapSet.new()
  end

  test "movie and tv_show with the same id are separate keys" do
    user = user_fixture()
    :ok = DiscoverIgnores.ignore(user, {:tmdb, 202}, :movie)

    keys = DiscoverIgnores.keys(user)

    assert keys == MapSet.new([{:movie, {:tmdb, 202}}])
    refute MapSet.member?(keys, {:tv_show, {:tmdb, 202}})
  end

  test "one user's ignores are invisible to another" do
    user_a = user_fixture()
    user_b = user_fixture()
    :ok = DiscoverIgnores.ignore(user_a, {:tmdb, 303}, :movie)

    assert DiscoverIgnores.keys(user_b) == MapSet.new()
  end

  test "deleting the user removes their ignores" do
    user = user_fixture()
    :ok = DiscoverIgnores.ignore(user, {:tmdb, 404}, :movie)

    {:ok, _} = Accounts.delete_user(user)

    assert Repo.aggregate(IgnoredDiscoverTitle, :count) == 0
  end

  test "tvdb refs round-trip" do
    user = user_fixture()
    :ok = DiscoverIgnores.ignore(user, {:tvdb, 303}, :tv_show)

    assert MapSet.member?(DiscoverIgnores.keys(user), {:tv_show, {:tvdb, 303}})
  end

  test "an invalid media type or provider is rejected" do
    bad_type =
      IgnoredDiscoverTitle.changeset(%IgnoredDiscoverTitle{}, %{
        media_type: "episode",
        provider: "tmdb",
        provider_id: 1
      })

    refute bad_type.valid?
    assert Keyword.has_key?(bad_type.errors, :media_type)

    bad_provider =
      IgnoredDiscoverTitle.changeset(%IgnoredDiscoverTitle{}, %{
        media_type: "movie",
        provider: "imdb",
        provider_id: 1
      })

    refute bad_provider.valid?
    assert Keyword.has_key?(bad_provider.errors, :provider)
  end
end
