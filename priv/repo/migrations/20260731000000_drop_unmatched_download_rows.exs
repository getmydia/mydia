defmodule Mydia.Repo.Migrations.DropUnmatchedDownloadRows do
  @moduledoc """
  Removes download rows that stood in for torrents Mydia does not manage.

  These rows are derived state: nothing writes `match_status = 'unmatched'` any
  more, and anything still sitting in a download client reappears immediately in
  `Mydia.Downloads.ExternalTorrents`, which recomputes the set on every scan.
  They carry no media item, no library path, and no imported files, and
  `DownloadMonitor` already deleted them unprompted whenever the torrent left
  the client.
  """

  use Ecto.Migration

  def up do
    execute("DELETE FROM downloads WHERE match_status = 'unmatched'")
  end

  def down do
    # Nothing to restore: the rows were derived from the download clients, and
    # the scan reproduces them on the next DownloadMonitor tick.
    :ok
  end
end
