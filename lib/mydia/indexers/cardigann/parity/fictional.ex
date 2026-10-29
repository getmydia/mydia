defmodule Mydia.Indexers.Cardigann.Parity.Fictional do
  @moduledoc """
  Deterministic invented names for scrubbing real release titles out of parity
  fixtures.

  A name is one word from each list, picked by hashing the real work name, so
  re-seeding the same capture produces the same fixture. The words are plain
  English nouns and adjectives chosen so that no pairing reads as an existing
  film or series title.
  """

  @adjectives ~w(Lantern Quiet Copper Amber Velvet Pewter Russet Hazel Tawny Brindle
                 Dappled Saffron Cobalt Mossy Sable Umber Ochre Briny Woolen Linen
                 Flinty Drowsy Nimble Rustic Wistful Placid Burnished Speckled Frosted
                 Muted Tidal Chalky Mellow Thistle Juniper Bracken Slate Willow Pebbled
                 Gusty)

  @nouns ~w(Harbor Orchard Meridian Thicket Causeway Quarry Lattice Bellows Cistern
            Arbor Trellis Spindle Furrow Gantry Paddock Pylon Sluice Bramble Rafter
            Wicket Kiln Cairn Dovecote Millrace Sconce Tannery Weir Ledger Parapet
            Plinth Culvert Gable Hearth Bower Turret Mooring Thimble Anvil Lintel
            Garret)

  @adjective_count length(@adjectives)
  @size @adjective_count * length(@nouns)

  @doc "A two-word invented name for `work`, stable across runs and never equal to it."
  @spec name(String.t()) :: String.t()
  def name(work) when is_binary(work) do
    index = :erlang.phash2(work, @size)
    candidate = at(index)

    if candidate == work, do: at(rem(index + 1, @size)), else: candidate
  end

  defp at(index) do
    adjective = Enum.at(@adjectives, rem(index, @adjective_count))
    noun = Enum.at(@nouns, div(index, @adjective_count))
    adjective <> " " <> noun
  end
end
