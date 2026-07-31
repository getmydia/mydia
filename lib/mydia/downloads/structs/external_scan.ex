defmodule Mydia.Downloads.Structs.ExternalScan do
  @moduledoc """
  The result of one pass over the download clients.

  `failed_clients` names the clients whose listing call errored. Without it an
  unreachable client is indistinguishable from a client with nothing foreign in
  it, and the UI would quietly under-report instead of saying so.
  """

  alias Mydia.Downloads.Structs.ExternalTorrent

  defstruct needs_matching: [], external: [], scanned_at: nil, failed_clients: []

  @type t :: %__MODULE__{
          needs_matching: [ExternalTorrent.t()],
          external: [ExternalTorrent.t()],
          scanned_at: DateTime.t() | nil,
          failed_clients: [String.t()]
        }

  @doc """
  The scan shown before the first refresh has landed.

  `scanned_at` is nil, which the UI reads as "not scanned yet" rather than
  "scanned and found nothing".
  """
  @spec empty() :: t()
  def empty, do: %__MODULE__{}
end
