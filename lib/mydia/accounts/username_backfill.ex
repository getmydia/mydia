defmodule Mydia.Accounts.UsernameBackfill do
  @moduledoc """
  Names the accounts that were created before logins derived a username.

  Every install that ran SSO has rows with `username: nil`, and the login path
  cannot reach an account whose owner does not sign in again. This is the pass
  that reaches them.

  Only the `:email` and `:sub` tiers are available here: `preferred_username`
  arrives in a login and nothing else. An account whose owner signs in later
  gets upgraded to the claim then.

  `run/0` always returns `:ok`. It is called from a migration, and
  `lib/mydia/application.ex` starts `{Ecto.Migrator, ...}` in the supervision
  tree, so a raise here would be a boot failure on every install rather than a
  failed deploy step. Both the read that finds nameless rows and the per-row
  work are guarded: a dropped connection or a decode error while listing the
  rows is caught here, and an exception naming one particular row is caught in
  `name_one/2`. A row it cannot name keeps `username: nil`, which is why
  `User.label/1` and `UsernameIndex` stay in place as guards.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Mydia.Accounts
  alias Mydia.Accounts.{User, UsernameSource}
  alias Mydia.Repo

  @spec run() :: :ok
  def run do
    case fetch_nameless_users() do
      {:ok, users} ->
        users
        |> Enum.reduce(%{named: 0, skipped: 0}, &name_one/2)
        |> log_stats()

        :ok

      :error ->
        :ok
    end
  end

  defp fetch_nameless_users do
    {:ok, Repo.all(nameless_users_query())}
  rescue
    error ->
      Logger.warning(
        "Username backfill could not read the user list: #{Exception.message(error)}"
      )

      :error
  end

  defp nameless_users_query do
    where(User, [u], is_nil(u.username) or fragment("trim(?)", u.username) == "")
  end

  defp log_stats(stats) do
    if stats.named > 0 or stats.skipped > 0 do
      Logger.info("Username backfill: named #{stats.named}, skipped #{stats.skipped}")
    end

    stats
  end

  defp name_one(%User{} = user, stats) do
    with {tier, slug} <- UsernameSource.derive(user),
         {:ok, _named} <- Accounts.claim_username(user, {tier, slug}) do
      %{stats | named: stats.named + 1}
    else
      _other -> skip(user, stats, "no usable name")
    end
  rescue
    error -> skip(user, stats, Exception.message(error))
  end

  defp skip(%User{id: id}, stats, reason) do
    Logger.warning("Username backfill skipped user #{id}: #{reason}")
    %{stats | skipped: stats.skipped + 1}
  end
end
