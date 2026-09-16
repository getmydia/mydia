defmodule Mydia.Repo.Migrations.RevokePrefixlessApiKeys do
  use Ecto.Migration

  # API keys created before 20251226020220 added the key_prefix column have no
  # prefix, and it cannot be recovered from an Argon2 hash. Verification now
  # narrows by prefix, so these keys can no longer authenticate. Revoke them so
  # the key's state is inspectable via the API and explicable in release notes,
  # instead of the key silently failing.
  def up do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    execute("""
    UPDATE api_keys SET revoked_at = '#{now}'
    WHERE key_prefix IS NULL AND revoked_at IS NULL
    """)
  end

  # Not reversible. Rolling back cannot distinguish keys this migration revoked
  # from keys the operator revoked by hand, and un-revoking a key on rollback is
  # the wrong default for a security action.
  def down, do: :ok
end
