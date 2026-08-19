defmodule Mydia.Jobs.DownloadMonitorRaceTest do
  @moduledoc """
  Issue #281: a download deleted mid-poll must not crash `DownloadMonitor` or
  stop the rest of the batch from being handled.

  `perform/1` calls `Downloads.list_downloads_with_status/1`, which reads every
  download row from the database and only *then* polls each configured client
  over HTTP. The six `Enum.each` passes that follow re-load each row by id. In
  production, seconds pass in between — long enough for an operator delete, a
  concurrent import, or the monitor's own reject path to remove a row. The
  reload then raised `Ecto.NoResultsError`, which aborted `perform/1` outright:
  356 occurrences across two instances in five weeks, each one also silently
  skipping every handler queued behind the failing one.

  The reproduction below needs no sleeps and cannot flake. Because the database
  read strictly precedes the HTTP call, deleting the row *inside the Bypass
  handler that answers the client poll* lands in that window on every single
  run.

  `async: false` is load-bearing, not incidental: `Mydia.DataCase` starts the
  sandbox with `shared: not tags[:async]`, and the Bypass handler runs in its
  own process, so only a shared connection lets it touch the database at all.
  """
  use Mydia.DataCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  import Ecto.Query

  alias Mydia.Downloads
  alias Mydia.Jobs.DownloadMonitor

  import Mydia.MediaFixtures
  import Mydia.DownloadsFixtures
  import Mydia.SettingsFixtures

  setup do
    bypass = Bypass.open()

    client_config =
      download_client_config_fixture(%{
        name: "race-client",
        type: "qbittorrent",
        host: "localhost",
        port: bypass.port
      })

    Bypass.stub(bypass, "POST", "/api/v2/auth/login", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("set-cookie", "SID=test-sid; HttpOnly")
      |> Plug.Conn.resp(200, "Ok.")
    end)

    {:ok, bypass: bypass, client: client_config}
  end

  test "a download deleted mid-poll neither crashes the job nor stops the batch", %{
    bypass: bypass,
    client: client
  } do
    media_item = media_item_fixture()

    vanishing = download_for(media_item, client, "vanishing-hash")
    survivor = download_for(media_item, client, "survivor-hash")

    delete_during_poll(bypass, vanishing)

    # Pre-fix this raises Ecto.NoResultsError straight out of perform_job/2.
    assert :ok = perform_job(DownloadMonitor, %{})

    assert Downloads.get_download(vanishing.id) == nil

    # The assertion that actually matters. "Did not crash" alone would still pass
    # if the poll bailed out after the vanished row; this proves the rest of the
    # batch was handled. Persisting `error_message` is what moves a row into the
    # Issues tab, so it is the observable outcome of `handle_missing/1`.
    reloaded = Downloads.get_download(survivor.id)
    refute is_nil(reloaded), "the surviving download was deleted by the poll"
    refute is_nil(reloaded.error_message), "the surviving download was never handled"
  end

  test "a poll where every download vanishes still completes", %{
    bypass: bypass,
    client: client
  } do
    media_item = media_item_fixture()
    doomed = download_for(media_item, client, "only-hash")

    delete_during_poll(bypass, doomed)

    assert :ok = perform_job(DownloadMonitor, %{})
    assert Downloads.get_download(doomed.id) == nil
  end

  defp download_for(media_item, client, hash) do
    download_fixture(%{
      media_item_id: media_item.id,
      download_client: client.name,
      download_client_id: hash
    })
  end

  # Answers the client poll with an empty torrent list — so every download reads
  # as "missing" and lands in `handle_missing/1` — and deletes `download` on the
  # way past. That deletion is the whole point: it happens after the monitor has
  # already read the rows and before any handler reloads one.
  #
  # `delete_all` rather than `delete!/1`: a single poll fans this endpoint out to
  # several readers (`UntrackedMatcher` and `ExternalTorrents` alongside the
  # monitor itself), so the stub runs more than once and the deletion has to be
  # idempotent. `delete!/1` on the second pass raises `Ecto.StaleEntryError`
  # inside the Bypass process and fails the test for the wrong reason.
  defp delete_during_poll(bypass, download) do
    test_pid = self()
    id = download.id

    Bypass.stub(bypass, "GET", "/api/v2/torrents/info", fn conn ->
      Ecto.Adapters.SQL.Sandbox.allow(Mydia.Repo, test_pid, self())
      Mydia.Repo.delete_all(from(d in Mydia.Downloads.Download, where: d.id == ^id))

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, "[]")
    end)
  end
end
