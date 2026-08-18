defmodule Mydia.Media.SeasonOrder do
  @moduledoc """
  TVDB season orderings and the remap between them.

  TVDB returns several orderings of the same series in one response. Mydia
  historically kept only the official one, which puts all 170 episodes of a
  show like Black Clover in a single season. The other orderings regroup the
  same episode records rather than describing different ones, which is what
  makes switching between them lossless.
  """

  @values [:official, :dvd, :absolute]

  @spec values() :: [atom()]
  def values, do: @values

  @doc """
  Maps an ordering to the `type.type` string TVDB uses in its season records.
  """
  @spec tvdb_type(atom() | nil) :: String.t()
  def tvdb_type(nil), do: "official"
  def tvdb_type(order) when order in @values, do: Atom.to_string(order)
end
