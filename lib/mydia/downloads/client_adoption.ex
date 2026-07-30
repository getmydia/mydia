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

    * **Torrent types only.** Only there is `download_client_id` a
      content-addressed info hash, stable across clients and identical when
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
end
