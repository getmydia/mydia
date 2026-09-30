defmodule Mydia.MediaServer.SeedResult do
  @moduledoc """
  What one account discovery pass did.

  Discovery is not all-or-nothing. An account matching no Mydia username is left
  alone, and so is an account some other Mydia user is already mapped to: moving
  that account to whoever's username happens to match would put two people on
  one watch history, which is the merge per-user mapping exists to prevent.
  An account whose Mydia user already has a mapping here is left alone for the
  same reason, because that mapping may deliberately pair names that differ.

  Those cases are counted rather than swallowed, because from the operator's
  side it looks like discovery ignored an account, and they need to know their
  own mapping is what stopped it.
  """

  alias Mydia.Settings.MediaServerUserLink

  @type t :: %__MODULE__{
          linked: [MediaServerUserLink.t()],
          already_mapped: [String.t()]
        }

  defstruct linked: [], already_mapped: []

  @spec add_link(t(), MediaServerUserLink.t()) :: t()
  def add_link(%__MODULE__{} = result, link), do: %{result | linked: [link | result.linked]}

  @spec add_already_mapped(t(), String.t() | nil) :: t()
  def add_already_mapped(%__MODULE__{} = result, name) do
    %{result | already_mapped: [name || "an account" | result.already_mapped]}
  end

  @doc "Puts every accumulated list back into the order it was seen."
  @spec finish(t()) :: t()
  def finish(%__MODULE__{} = result) do
    %{
      result
      | linked: Enum.reverse(result.linked),
        already_mapped: Enum.reverse(result.already_mapped)
    }
  end
end
