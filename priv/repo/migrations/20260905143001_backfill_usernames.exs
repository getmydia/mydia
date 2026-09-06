defmodule Mydia.Repo.Migrations.BackfillUsernames do
  use Ecto.Migration

  @moduledoc """
  Names the accounts that OIDC created before logins derived a username.

  The work lives in `Mydia.Accounts.UsernameBackfill` so it can be tested like
  ordinary code rather than only through a migration, the way
  `20260902200320_relink_existing_multi_episode_files.exs` delegates to
  `Mydia.Library.MultiEpisodeRelink`.

  `run/0` cannot fail. That is deliberate: this runs inside the supervision
  tree's migrator, so a raise would stop the application booting.
  """

  def up do
    :ok = Mydia.Accounts.UsernameBackfill.run()
  end

  def down do
    # The names are real data by now, and dropping them would put every
    # install back in the state that produced the crash this fixes.
    :ok
  end
end
