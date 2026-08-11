defmodule Mydia.MediaServer.Error do
  @moduledoc """
  A classified media server failure.

  The distinction matters operationally: `:auth` means the operator must
  reconnect, `:unreachable` means the address may have moved and rediscovery
  should run. Collapsing both into a string (the previous behaviour) made a
  revoked token look identical to a network timeout.
  """

  @type kind :: :auth | :unreachable | :unexpected

  @type t :: %__MODULE__{kind: kind(), detail: String.t()}

  defstruct [:kind, :detail]

  @spec auth(String.t()) :: t()
  def auth(detail), do: %__MODULE__{kind: :auth, detail: detail}

  @spec unreachable(String.t()) :: t()
  def unreachable(detail), do: %__MODULE__{kind: :unreachable, detail: detail}

  @spec unexpected(String.t()) :: t()
  def unexpected(detail), do: %__MODULE__{kind: :unexpected, detail: detail}

  @doc "Human-readable message for UI display."
  @spec message(t()) :: String.t()
  def message(%__MODULE__{kind: :auth, detail: d}), do: "Authentication failed: #{d}"
  def message(%__MODULE__{kind: :unreachable, detail: d}), do: "Server unreachable: #{d}"
  def message(%__MODULE__{kind: :unexpected, detail: d}), do: "Unexpected response: #{d}"
end
