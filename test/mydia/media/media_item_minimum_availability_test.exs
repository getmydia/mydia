defmodule Mydia.Media.MediaItemMinimumAvailabilityTest do
  use ExUnit.Case, async: true

  alias Mydia.Media.MediaItem

  defp changeset(level) do
    MediaItem.changeset(%MediaItem{type: "movie", title: "Copper Weather", year: 2031}, %{
      minimum_availability: level
    })
  end

  test "accepts each level" do
    for level <- ["announced", "in_cinemas", "released"] do
      cs = changeset(level)
      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :minimum_availability) == level
    end
  end

  test "accepts nil, meaning follow the server setting" do
    cs = changeset(nil)
    assert cs.valid?
    assert Ecto.Changeset.get_field(cs, :minimum_availability) == nil
  end

  test "stores a blank value as nil" do
    cs = changeset("")
    assert cs.valid?
    assert Ecto.Changeset.get_field(cs, :minimum_availability) == nil
  end

  test "rejects an unknown level" do
    refute changeset("soon").valid?
  end
end
