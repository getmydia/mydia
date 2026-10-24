defmodule MydiaWeb.DownloadsLive.IssueList do
  @moduledoc """
  The Issues list: classifies downloads and client torrents awaiting a match
  into `MydiaWeb.DownloadsLive.Issue` rows, orders, counts and filters them.
  Pure: touches no Repo and no socket.
  """

  use Gettext, backend: MydiaWeb.Gettext

  alias MydiaWeb.DownloadsLive.{Filters, Issue, ListView}

  @kind_keys [
    :needs_matching,
    :unresolved,
    :import_failed,
    :download_failed,
    :missing,
    :removal_failed
  ]
  @kind_order @kind_keys |> Enum.with_index() |> Map.new()
  @kind_strings Map.new(@kind_keys, &{Atom.to_string(&1), &1})

  @spec kinds() :: [{Issue.kind(), String.t()}]
  def kinds, do: Enum.map(@kind_keys, &{&1, label(&1)})

  @spec label(Issue.kind()) :: String.t()
  def label(:needs_matching), do: gettext("Needs matching")
  def label(:unresolved), do: gettext("Unresolved files")
  def label(:import_failed), do: gettext("Import failed")
  def label(:download_failed), do: gettext("Download failed")
  def label(:missing), do: gettext("Missing from client")
  def label(:removal_failed), do: gettext("Couldn't remove")

  @spec parse_kind(String.t() | nil) :: Issue.kind() | nil
  def parse_kind(value), do: Map.get(@kind_strings, value)

  @doc """
  The issue a download represents, or nil. The first matching rule wins: an
  unresolved match outranks everything, and a removal still pending outranks
  the failure that preceded it, since it is what the user must resolve first.
  A client error on a download that already imported is not an issue:
  retrying it would re-grab the release.
  """
  @spec kind(map()) :: Issue.kind() | nil
  def kind(download) do
    cond do
      download.match_status == "unresolved_files" -> :unresolved
      not is_nil(download.removal_error) -> :removal_failed
      not is_nil(download.import_failed_at) -> :import_failed
      download.status == "failed" and is_nil(download.imported_at) -> :download_failed
      download.status == "missing" -> :missing
      true -> nil
    end
  end

  @doc """
  Issue rows for client torrents awaiting a match plus the downloads that are
  issues, ordered by kind (chip order), then most recent first.
  """
  @spec build([struct()], [map()]) :: [Issue.t()]
  def build(scan_items, downloads) do
    from_scan = Enum.map(scan_items, &from_torrent/1)

    from_downloads =
      Enum.flat_map(downloads, fn download ->
        case kind(download) do
          nil -> []
          kind -> [from_download(download, kind)]
        end
      end)

    Enum.sort_by(from_scan ++ from_downloads, &sort_key/1)
  end

  @spec counts([Issue.t()]) :: %{Issue.kind() => non_neg_integer()}
  def counts(issues) do
    base = Map.new(@kind_keys, &{&1, 0})
    Enum.reduce(issues, base, fn %Issue{kind: kind}, acc -> Map.update!(acc, kind, &(&1 + 1)) end)
  end

  @spec filter([Issue.t()], Filters.t()) :: [Issue.t()]
  def filter(issues, %Filters{q: q, client: client, kind: kind}) do
    Enum.filter(issues, fn issue ->
      (is_nil(kind) or issue.kind == kind) and
        (is_nil(client) or issue.client == client) and
        ListView.matches_query?([issue.title, issue.subtitle], q)
    end)
  end

  # Kind in chip order, then newest first; scan items (no timestamp) by title.
  defp sort_key(%Issue{kind: kind, updated_at: at, title: title}) do
    {Map.fetch!(@kind_order, kind), -timestamp(at), title}
  end

  defp timestamp(nil), do: 0
  defp timestamp(%DateTime{} = at), do: DateTime.to_unix(at, :microsecond)
  defp timestamp(%NaiveDateTime{} = at), do: at |> DateTime.from_naive!("Etc/UTC") |> timestamp()

  defp from_torrent(torrent) do
    %Issue{
      kind: :needs_matching,
      id: torrent.id,
      title: torrent.title,
      subtitle:
        torrent.parsed && torrent.parsed.title &&
          gettext("Parsed: %{title}", title: torrent.parsed.title),
      reason: gettext("No library match"),
      client: torrent.client_name,
      torrent: torrent
    }
  end

  defp from_download(download, kind) do
    title = ListView.display_title(download)

    %Issue{
      kind: kind,
      id: download.id,
      title: title,
      subtitle: if(title != download.title, do: download.title),
      reason: reason(kind, download),
      client: download.download_client,
      media_item_id: ListView.media_item_id(download),
      updated_at: download.updated_at,
      download: download
    }
  end

  defp reason(:unresolved, _download), do: gettext("Some files could not be matched")

  defp reason(:removal_failed, download),
    do:
      gettext("Couldn't remove from %{client}: %{error}",
        client: download.download_client,
        error: download.removal_error
      )

  defp reason(:import_failed, download),
    do:
      gettext("Import failed: %{error}",
        error: download.import_last_error || gettext("unknown error")
      )

  defp reason(:download_failed, download),
    do:
      gettext("Download failed: %{error}",
        error: download.error_message || gettext("unknown error")
      )

  defp reason(:missing, _download), do: gettext("Removed from client")
end
