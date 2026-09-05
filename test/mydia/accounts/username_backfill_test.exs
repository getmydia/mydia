defmodule Mydia.Accounts.UsernameBackfillTest do
  # Not async. "returns :ok when the user list cannot be read" renames the
  # users table inside its sandbox transaction, and on PostgreSQL that rename
  # holds an ACCESS EXCLUSIVE lock until the transaction ends. Any other async
  # test touching users would block on it and eventually time out, which is the
  # flake class .github/ci-flakes.md already catalogues.
  use Mydia.DataCase, async: false

  import Mydia.AccountsFixtures

  alias Mydia.Accounts.UsernameBackfill
  alias Mydia.Repo

  test "names an account from its email" do
    user = nameless_user_fixture(%{email: "robin.vega@example.test"})

    assert UsernameBackfill.run() == :ok

    reloaded = Repo.reload(user)
    assert reloaded.username == "robin.vega"
    assert reloaded.username_source == "email"
  end

  test "falls back to the sub when there is no email" do
    user = nameless_user_fixture(%{email: nil, oidc_sub: "abcdef1234567890"})

    assert UsernameBackfill.run() == :ok

    reloaded = Repo.reload(user)
    assert reloaded.username == "oidc-abcdef12"
    assert reloaded.username_source == "sub"
  end

  test "suffixes past a name a local account already holds" do
    _taken = user_fixture(%{username: "robin"})
    user = nameless_user_fixture(%{email: "robin@example.test"})

    assert UsernameBackfill.run() == :ok
    assert Repo.reload(user).username == "robin-2"
  end

  test "leaves accounts that already have a name alone" do
    local = user_fixture(%{username: "installer"})

    assert UsernameBackfill.run() == :ok

    reloaded = Repo.reload(local)
    assert reloaded.username == "installer"
    assert reloaded.username_source == nil
  end

  test "skips a row it cannot name rather than failing" do
    unnameable = nameless_user_fixture(%{email: nil, oidc_sub: nil})
    nameable = nameless_user_fixture(%{email: "robin@example.test"})

    assert UsernameBackfill.run() == :ok
    assert Repo.reload(unnameable).username == nil
    assert Repo.reload(nameable).username == "robin"
  end

  test "is safe to run twice" do
    user = nameless_user_fixture(%{email: "robin@example.test"})

    assert UsernameBackfill.run() == :ok
    assert UsernameBackfill.run() == :ok

    assert Repo.reload(user).username == "robin"
  end

  test "returns :ok even when the read that finds nameless rows fails" do
    # Renaming the table out from under the query is the cleanest way to make
    # Repo.all/1 raise inside a sandboxed test: both SQLite and PostgreSQL
    # support this DDL, and the sandbox transaction rolls it back regardless.
    # The rename-back also happens explicitly in `after`, so a failing
    # assertion here cannot leave the schema broken for the rest of the file.
    Repo.query!("ALTER TABLE users RENAME TO users_backfill_test_tmp")

    try do
      assert UsernameBackfill.run() == :ok
    after
      Repo.query!("ALTER TABLE users_backfill_test_tmp RENAME TO users")
    end
  end
end
