defmodule Mydia.Repo.Migrations.AddPromotingStateToTorrentSessions do
  @moduledoc """
  Adds a `:promoting` state to torrent_streaming_sessions to act as an atomic
  claim during the playback-threshold promotion window. Two concurrent
  save_progress callers could otherwise both observe `state == :watching`,
  both call `Promotion.promote/1`, and either double-create MediaFiles or
  race File.rename on the staging file.

  The partial unique infohash index already excludes terminal states; extend
  it to also exclude `:promoting` so a second viewer doesn't get blocked from
  starting their own session while the first viewer's session is mid-promotion.
  """
  use Ecto.Migration

  def up do
    drop unique_index(:torrent_streaming_sessions, [:infohash],
           where: "state NOT IN ('completed', 'failed', 'cancelled')"
         )

    create unique_index(:torrent_streaming_sessions, [:infohash],
             where: "state NOT IN ('completed', 'failed', 'cancelled', 'promoting')"
           )
  end

  def down do
    drop unique_index(:torrent_streaming_sessions, [:infohash],
           where: "state NOT IN ('completed', 'failed', 'cancelled', 'promoting')"
         )

    create unique_index(:torrent_streaming_sessions, [:infohash],
             where: "state NOT IN ('completed', 'failed', 'cancelled')"
           )
  end
end
