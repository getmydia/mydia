defmodule Mydia.Config.HwaccelConfigTest do
  use ExUnit.Case, async: true

  alias Mydia.Config.Schema

  defp changeset(attrs) do
    Schema.changeset(%Schema{}, %{"streaming" => attrs})
  end

  describe "hwaccel" do
    test "defaults to auto" do
      assert %Schema{streaming: %{hwaccel: :auto}} = Schema.defaults()
    end

    test "accepts the supported backends" do
      for value <- ["auto", "off", "vaapi"] do
        assert changeset(%{"hwaccel" => value}).valid?, "expected #{value} to be accepted"
      end
    end

    test "rejects an unknown backend by name rather than defaulting" do
      # An operator who typos a safety-relevant setting must get an error, not
      # silently get `auto`. :invalid is not a member of the Ecto.Enum, so
      # validation rejects it.
      refute changeset(%{"hwaccel" => "vappi"}).valid?
    end
  end

  describe "hwaccel_device" do
    test "accepts a render node path" do
      cs = changeset(%{"hwaccel_device" => "/dev/dri/renderD129"})

      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :streaming).hwaccel_device == "/dev/dri/renderD129"
    end
  end
end
