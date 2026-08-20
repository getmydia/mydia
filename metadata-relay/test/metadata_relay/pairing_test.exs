defmodule MetadataRelay.PairingTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias MetadataRelay.Pairing

  setup do
    # Ensure ETS table exists for fallback
    Pairing.ensure_ets_table()

    # Clear the ETS table before each test
    if :ets.whereis(:pairing_claims) != :undefined do
      :ets.delete_all_objects(:pairing_claims)
    end

    :ok
  end

  @valid_node_addr Jason.encode!(%{
                     "relay_url" => "https://relay.example.com",
                     "node_id" => "abc123def456"
                   })

  describe "create_claim/2" do
    test "creates a claim with valid node_addr" do
      assert {:ok, claim} = Pairing.create_claim(@valid_node_addr)
      assert String.length(claim.code) == 6
      assert claim.node_addr == @valid_node_addr
      assert claim.expires_at != nil
    end

    test "respects custom TTL" do
      before = DateTime.utc_now()
      assert {:ok, claim} = Pairing.create_claim(@valid_node_addr, ttl_seconds: 600)
      after_plus_600 = DateTime.add(before, 600, :second)

      diff = DateTime.diff(claim.expires_at, after_plus_600, :second)
      assert abs(diff) < 2
    end

    test "respects custom code" do
      assert {:ok, claim} = Pairing.create_claim(@valid_node_addr, code: "CUSTOM")
      assert claim.code == "CUSTOM"
    end

    test "uppercases code" do
      assert {:ok, claim} = Pairing.create_claim(@valid_node_addr, code: "mycode")
      assert claim.code == "MYCODE"
    end
  end

  describe "get_claim/1" do
    test "returns node_addr for valid code" do
      {:ok, claim} = Pairing.create_claim(@valid_node_addr)
      assert {:ok, node_addr} = Pairing.get_claim(claim.code)
      assert node_addr == @valid_node_addr
    end

    test "returns error for non-existent code" do
      assert {:error, :not_found} = Pairing.get_claim("NONEXISTENT")
    end

    test "returns error for expired code (ETS fallback)" do
      # Create an expired claim using ETS directly
      Pairing.ensure_ets_table()
      expires_at = System.system_time(:second) - 10
      :ets.insert(:pairing_claims, {"EXPTEST", @valid_node_addr, expires_at})

      assert {:error, :not_found} = Pairing.get_claim("EXPTEST")
    end

    test "normalizes code (case insensitive)" do
      {:ok, claim} = Pairing.create_claim(@valid_node_addr)
      assert {:ok, _} = Pairing.get_claim(String.downcase(claim.code))
    end

    test "normalizes code (strips dashes and spaces)" do
      {:ok, _claim} = Pairing.create_claim(@valid_node_addr, code: "ABCDEF")

      # Should work with dashes
      assert {:ok, _} = Pairing.get_claim("ABC-DEF")

      # Should work with spaces
      assert {:ok, _} = Pairing.get_claim("ABC DEF")

      # Should work with mixed
      assert {:ok, _} = Pairing.get_claim("abc-def")
    end
  end

  describe "delete_claim/1" do
    test "deletes existing claim" do
      {:ok, claim} = Pairing.create_claim(@valid_node_addr)
      assert :ok = Pairing.delete_claim(claim.code)

      # Should not be findable anymore
      assert {:error, :not_found} = Pairing.get_claim(claim.code)
    end

    test "returns ok for non-existent claim (idempotent)" do
      assert :ok = Pairing.delete_claim("NONEXISTENT")
    end

    test "normalizes code on delete" do
      {:ok, _claim} = Pairing.create_claim(@valid_node_addr, code: "DELETE")
      assert :ok = Pairing.delete_claim("del-ete")
    end
  end

  describe "generate_code/1" do
    test "generates 6 character code by default" do
      code = Pairing.generate_code()
      assert String.length(code) == 6
    end

    test "generates code with custom length" do
      code = Pairing.generate_code(8)
      assert String.length(code) == 8

      code = Pairing.generate_code(4)
      assert String.length(code) == 4
    end

    test "uses only allowed characters" do
      # Alphabet without ambiguous characters
      alphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"

      for _ <- 1..100 do
        code = Pairing.generate_code()

        code
        |> String.graphemes()
        |> Enum.each(fn char ->
          assert String.contains?(alphabet, char),
                 "Code contains invalid character: #{char}"
        end)
      end
    end

    test "generates unique codes (cryptographic randomness)" do
      codes =
        1..1000
        |> Enum.map(fn _ -> Pairing.generate_code() end)
        |> MapSet.new()

      assert MapSet.size(codes) == 1000,
             "Generated codes are not sufficiently random - found duplicates"
    end

    test "excludes ambiguous characters (O, 0, I, 1, L)" do
      ambiguous = ["O", "0", "I", "1", "L"]

      for _ <- 1..100 do
        code = Pairing.generate_code()

        Enum.each(ambiguous, fn char ->
          refute String.contains?(code, char),
                 "Code contains ambiguous character: #{char}"
        end)
      end
    end
  end

  describe "sealed claims (v2)" do
    setup do
      MetadataRelay.Pairing.init_ets_table()
      :ok
    end

    test "stores and fetches a sealed blob by lookup key" do
      key = String.duplicate("a", 64)
      assert :ok = MetadataRelay.Pairing.store_sealed(key, "c2VhbGVk")
      assert {:ok, "c2VhbGVk"} = MetadataRelay.Pairing.fetch_sealed(key)
    end

    test "returns not_found for an unknown lookup key" do
      assert {:error, :not_found} =
               MetadataRelay.Pairing.fetch_sealed(String.duplicate("b", 64))
    end

    test "deletes a sealed blob" do
      key = String.duplicate("c", 64)
      :ok = MetadataRelay.Pairing.store_sealed(key, "c2VhbGVk")
      assert :ok = MetadataRelay.Pairing.delete_sealed(key)
      assert {:error, :not_found} = MetadataRelay.Pairing.fetch_sealed(key)
    end

    test "v1 and v2 namespaces do not collide" do
      key = String.duplicate("d", 64)
      :ok = MetadataRelay.Pairing.store_sealed(key, "sealed-value")
      assert {:error, :not_found} = MetadataRelay.Pairing.get_claim(key)
    end
  end
end
