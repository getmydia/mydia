defmodule Mydia.Repo.Migrations.MoveSubtitleLanguageToDownloads do
  @moduledoc """
  Moves the subtitle acquisition list from the `streaming.subtitle_language`
  row of `config_settings` to `downloads.subtitle_language`.

  The key has only ever meant "which subtitle languages to go and get", so an
  existing row is unambiguously an acquisition value. From this release
  `streaming.subtitle_language` means the subtitle that plays, so leaving the
  row where it is would both lose the operator's acquisition setting and
  switch subtitles on for every show they own.

  A row under the destination key already existing means the move has run, so
  the source row is dropped rather than overwriting it.
  """

  use Ecto.Migration

  import Mydia.Repo.Migrations.Helpers

  @from "streaming.subtitle_language"
  @to "downloads.subtitle_language"

  def up do
    if destination_exists?() do
      execute("DELETE FROM config_settings WHERE key = '#{@from}'")
    else
      execute(
        "UPDATE config_settings SET key = '#{@to}', category = 'downloads' " <>
          "WHERE key = '#{@from}'"
      )
    end
  end

  def down do
    # `up/0` freed this key for its new meaning, so an operator may since have
    # written a playback value under it. That key does not mean "which subtitle
    # plays" in the world this rolls back to, and the row would collide with
    # the unique index on `key`, so it is dropped rather than merged.
    #
    # Delete before the rename, not after: the rename is what collides.
    execute("DELETE FROM config_settings WHERE key = '#{@from}'")

    execute(
      "UPDATE config_settings SET key = '#{@from}', category = 'streaming' " <>
        "WHERE key = '#{@to}'"
    )
  end

  # SQLite binds with `?` and PostgreSQL with `$1`, so the placeholder is the
  # one thing in this migration that cannot be written once.
  defp destination_exists? do
    sql =
      if postgres?() do
        "SELECT COUNT(*) FROM config_settings WHERE key = $1"
      else
        "SELECT COUNT(*) FROM config_settings WHERE key = ?"
      end

    %{rows: [[count]]} = repo().query!(sql, [@to])

    count > 0
  end
end
