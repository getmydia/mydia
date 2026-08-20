defmodule Mydia.RemoteAccess.PairingClaimTest do
  use Mydia.DataCase, async: true

  alias Mydia.RemoteAccess.PairingClaim

  describe "generate_code/0" do
    test "returns six characters from the unambiguous alphabet" do
      for _ <- 1..50 do
        code = PairingClaim.generate_code()
        assert String.length(code) == 6
        assert code =~ ~r/\A[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{6}\z/
      end
    end

    test "does not emit characters that are easy to misread" do
      codes = Enum.map_join(1..200, "", fn _ -> PairingClaim.generate_code() end)

      for ambiguous <- ["0", "O", "1", "I", "L"] do
        refute String.contains?(codes, ambiguous)
      end
    end

    test "produces distinct codes" do
      codes = Enum.map(1..50, fn _ -> PairingClaim.generate_code() end)
      assert length(Enum.uniq(codes)) > 45
    end
  end

  describe "changeset_with_code/2" do
    test "accepts a lookup key" do
      attrs = %{
        user_id: Ecto.UUID.generate(),
        code: "K7RPM2",
        lookup_key: String.duplicate("a", 64),
        expires_at: DateTime.utc_now() |> DateTime.add(300) |> DateTime.truncate(:second)
      }

      changeset = PairingClaim.changeset_with_code(%PairingClaim{}, attrs)

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :lookup_key) == attrs.lookup_key
    end

    test "requires a lookup key" do
      attrs = %{
        user_id: Ecto.UUID.generate(),
        code: "K7RPM2",
        expires_at: DateTime.utc_now() |> DateTime.add(300) |> DateTime.truncate(:second)
      }

      refute PairingClaim.changeset_with_code(%PairingClaim{}, attrs).valid?
    end
  end

  test "relay_registered is virtual and defaults to false" do
    assert %PairingClaim{}.relay_registered == false
    refute :relay_registered in PairingClaim.__schema__(:fields)
  end
end
