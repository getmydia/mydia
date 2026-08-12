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

  `owner_fallback` records what Plex's no-Home fallback did, which is neither a
  name match nor a mapping left alone and must not be reported as either.
  """

  alias Mydia.Settings.MediaServerUserLink

  @typedoc """
  What the Plex owner fallback did on this pass.

    * `nil` - it did not run, either because the server reported Home profiles
      or because something was already mapped.
    * `:linked` - the server reported no Home profiles and the single admin user
      was bound to the config's own token. Nothing matched by name.
    * `:ambiguous` - the server reported no Home profiles and this install has
      more than one admin, so nothing was written. `config.token` belongs to
      whoever ran OAuth and picking an admin by query order would hand one
      admin another admin's Plex account.
  """
  @type owner_fallback :: nil | :linked | :ambiguous

  @type t :: %__MODULE__{
          linked: [MediaServerUserLink.t()],
          already_mapped: [String.t()],
          owner_fallback: owner_fallback()
        }

  defstruct linked: [], already_mapped: [], owner_fallback: nil

  @spec add_link(t(), MediaServerUserLink.t()) :: t()
  def add_link(%__MODULE__{} = result, link), do: %{result | linked: [link | result.linked]}

  @spec add_already_mapped(t(), String.t() | nil) :: t()
  def add_already_mapped(%__MODULE__{} = result, name) do
    %{result | already_mapped: [name || "an account" | result.already_mapped]}
  end

  @doc "Puts both accumulated lists back into the order they were seen."
  @spec finish(t()) :: t()
  def finish(%__MODULE__{} = result) do
    %{
      result
      | linked: Enum.reverse(result.linked),
        already_mapped: Enum.reverse(result.already_mapped)
    }
  end
end
