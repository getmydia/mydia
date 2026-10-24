defmodule MydiaWeb.DownloadsLive.Rows do
  @moduledoc """
  The Downloads tab's rows: what is stamped on them before they render
  (rematch eligibility, the auto-reject cap), the stale-status banner derived
  from them, and how page 0 reaches the `:downloads` stream without resetting
  it, so a click pressed across a refresh still fires (issue #1257).
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [stream: 3, stream: 4, stream_delete_by_dom_id: 3]

  alias Mydia.Downloads.AutoRejectCap
  alias Mydia.Library
  alias MydiaWeb.DownloadsLive.ListView

  @doc "Stamps the per-row flags the list needs: rematch eligibility, then the auto-reject cap."
  def annotate(downloads) do
    downloads
    |> annotate_rematch_eligibility()
    |> annotate_auto_reject_cap()
  end

  # Stamps `rematch_eligible?` on imported rows: a row is eligible only when it
  # resolves to exactly one non-trashed imported file. Packs resolve to several
  # files and can't be re-matched as a unit, so the action stays hidden for them
  # even though their `match_status` is nil. In-flight rows don't offer the
  # action, so they are left nil and cost no query.
  defp annotate_rematch_eligibility(downloads) do
    imported_ids = for %{imported_at: at, id: id} <- downloads, not is_nil(at), do: id

    counts =
      if imported_ids == [],
        do: %{},
        else: Library.count_imported_files_by_download(imported_ids)

    Enum.map(downloads, fn
      %{imported_at: nil} = download -> download
      download -> %{download | rematch_eligible?: Map.get(counts, download.id, 0) == 1}
    end)
  end

  # Stamps `auto_reject_capped?` so a stalled row whose title has used up its
  # automatic rejections says so, instead of counting down to a removal that
  # DownloadMonitor will not make. One query for the whole page.
  defp annotate_auto_reject_cap(downloads) do
    capped =
      downloads
      |> Enum.map(& &1.media_item_id)
      |> AutoRejectCap.exhausted_ids()

    Enum.map(downloads, fn download ->
      %{download | auto_reject_capped?: MapSet.member?(capped, download.media_item_id)}
    end)
  end

  # The oldest last-known status among the rows about to render, when a client
  # was too busy to answer the page's bounded poll. nil when every row is live.
  def stale_status(downloads) do
    downloads
    |> Enum.filter(& &1.status_as_of)
    |> Enum.min_by(& &1.status_as_of, DateTime, fn -> nil end)
    |> case do
      nil -> nil
      row -> %{client: row.download_client, as_of: row.status_as_of}
    end
  end

  # Page 0 of the Downloads list. A stream reset detaches every row, and a
  # click pressed across that detach never fires (issue #1257), so rows that
  # kept their order are patched in place and only gone rows are deleted.
  def stream_page(socket, rows) do
    ids = Enum.map(rows, & &1.id)

    socket =
      case ListView.stream_plan(socket.assigns.stream_ids, ids) do
        {:update, removed_ids} ->
          removed_ids
          |> Enum.reduce(socket, &stream_delete_by_dom_id(&2, :downloads, "downloads-#{&1}"))
          |> stream(:downloads, rows)

        :reset ->
          stream(socket, :downloads, rows, reset: true)
      end

    assign(socket, :stream_ids, ids)
  end
end
