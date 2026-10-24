defmodule MydiaWeb.DownloadsLive.Issue do
  @moduledoc """
  One row of the Downloads page's Issues list, built by
  `MydiaWeb.DownloadsLive.IssueList.build/2`.

  Exactly one of `download` (a download row) and `torrent` (a client torrent
  awaiting a match, which has no download row) is set.
  """

  @enforce_keys [:kind, :id, :title]
  defstruct [
    :kind,
    :id,
    :title,
    :subtitle,
    :reason,
    :client,
    :media_item_id,
    :updated_at,
    :download,
    :torrent
  ]

  @type kind ::
          :needs_matching
          | :unresolved
          | :import_failed
          | :download_failed
          | :missing
          | :removal_failed

  @type t :: %__MODULE__{
          kind: kind(),
          id: String.t(),
          title: String.t(),
          subtitle: String.t() | nil,
          reason: String.t() | nil,
          client: String.t() | nil,
          media_item_id: String.t() | nil,
          updated_at: DateTime.t() | NaiveDateTime.t() | nil,
          download: map() | nil,
          torrent: Mydia.Downloads.Structs.ExternalTorrent.t() | nil
        }

  @doc "Whether the row can be selected for a batch action (it has a download row)."
  @spec selectable?(t()) :: boolean()
  def selectable?(%__MODULE__{download: download}), do: not is_nil(download)
end
