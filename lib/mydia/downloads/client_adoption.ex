defmodule Mydia.Downloads.ClientAdoption do
  @moduledoc """
  Decides whether a download whose client is gone can be re-adopted by a
  client that is still configured.

  Clients are identified by name, so renaming one is indistinguishable from
  deleting it. When that happens the torrent itself is usually still sitting
  in the same daemon under a new client name, and `DownloadMonitor` already
  holds every configured client's torrent list from its regular poll. This
  module turns that list into an adoption decision.

  ## The rule

  Adopt only when *exactly one* reachable client reports the download's
  `download_client_id`, and only when that client is a torrent type.

  Both halves are load-bearing:

    * **Single claimant.** Two clients can legitimately hold the same info
      hash (the same release seeded in two places). Since commit 96d75b00
      scoped every client to its own files, adopting onto the wrong claimant
      means importing from the wrong `save_path`.

    * **Torrent types only.** `download_client_id` is a content-addressed info
      hash only for these types, stable across clients and identical when
      the same daemon is re-added under a different name. Usenet clients use
      `nzo_id` or numeric ids that are client-local and recycled; debrid ids
      are meaningful only to the provider that issued them. A cross-client
      match on either is coincidence, not identity. `:blackhole` is a watch
      directory with no listing API, so it can never appear as a claimant
      regardless.

  This module is deliberately pure: no database, no network. It is the whole
  decision surface for adoption, so its tests are the whole edge-case suite.
  """

  @adoptable_types [:qbittorrent, :transmission, :rqbit, :rtorrent]

  # The copy the previously released code wrote for every client-gone case,
  # before this feature existed to tell them apart. Rows carrying it are
  # orphans with no tag.
  @legacy_orphan_message_prefix "Removed from download client"

  @typedoc "Poll results, exactly as `History.fetch_all_client_statuses/2` returns them."
  @type client_statuses :: %{String.t() => {:reachable, map()} | :unreachable}

  @typedoc "Client name to its configured adapter type."
  @type client_types :: %{String.t() => atom()}

  @doc """
  The client types whose `download_client_id` is a portable, content-addressed
  identifier.
  """
  @spec adoptable_types() :: [atom()]
  def adoptable_types, do: @adoptable_types

  @doc """
  Returns `{:ok, client_name}` when exactly one reachable torrent-type client
  reports `client_id`, and `:none` otherwise.

  `:none` covers every ambiguous or unsafe case: no claimant, several
  claimants, a claimant of a non-adoptable type, and a claimant whose type is
  unknown.
  """
  @spec find_claimant(String.t() | nil, client_statuses(), client_types()) ::
          {:ok, String.t()} | :none
  def find_claimant(nil, _client_statuses, _client_types), do: :none

  def find_claimant(client_id, client_statuses, client_types) do
    claimants =
      for {name, {:reachable, torrents}} <- client_statuses,
          Map.has_key?(torrents, client_id),
          Map.get(client_types, name) in @adoptable_types,
          do: name

    case claimants do
      [only_claimant] -> {:ok, only_claimant}
      _ambiguous_or_empty -> :none
    end
  end

  @doc """
  Whether a download's persisted failure state is orphan state this feature
  owns, and may therefore clear when a client picks the download back up.

  True for the `"no_client"` tag, and for a legacy row carrying the previously
  released "Removed from download client ..." message with no tag at all (the
  tag did not exist when it was written). False for every other failure: a
  genuine import failure always sets `import_failure_reason`, and adoption
  fixes which client owns a torrent, it does not vindicate a broken import.

  Lives here, next to the adoption rule, because the read path
  (`Mydia.Downloads.History`) and the writer (`Mydia.Jobs.DownloadMonitor`)
  must agree on it exactly. If the read path proposed a heal the writer then
  declined to perform, the monitor would re-propose it on every poll and
  broadcast a download update each time.
  """
  @spec orphan_state?(String.t() | nil, String.t() | nil) :: boolean()
  def orphan_state?("no_client", _error_message), do: true

  def orphan_state?(nil, error_message) when is_binary(error_message),
    do: String.starts_with?(error_message, @legacy_orphan_message_prefix)

  def orphan_state?(_import_failure_reason, _error_message), do: false
end
