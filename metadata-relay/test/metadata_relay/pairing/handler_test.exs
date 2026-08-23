defmodule MetadataRelay.Pairing.HandlerTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias MetadataRelay.Router
  alias MetadataRelay.Pairing

  setup do
    # Ensure ETS table exists for fallback
    Pairing.ensure_ets_table()

    # Clear the ETS table before each test
    if :ets.whereis(:pairing_claims) != :undefined do
      :ets.delete_all_objects(:pairing_claims)
    end

    # Start the rate limiter if not already started
    case GenServer.whereis(MetadataRelay.RateLimiter) do
      nil -> start_supervised!(MetadataRelay.RateLimiter)
      _pid -> :ok
    end

    # Clear the rate limiter table before each test
    :ets.delete_all_objects(:rate_limiter)

    :ok
  end

  @valid_node_addr Jason.encode!(%{
                     "relay_url" => "https://relay.example.com",
                     "node_id" => "abc123def456"
                   })

  describe "POST /pairing/claim" do
    test "creates a claim and returns claim_code" do
      params = %{"node_addr" => @valid_node_addr}

      conn =
        Plug.Test.conn(:post, "/pairing/claim", params)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
        |> Router.call([])

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)
      assert is_binary(response["claim_code"])
      assert String.length(response["claim_code"]) == 6
    end

    test "returns 400 when node_addr is missing" do
      conn =
        Plug.Test.conn(:post, "/pairing/claim", %{})
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
        |> Router.call([])

      assert conn.status == 400
      response = Jason.decode!(conn.resp_body)
      assert response["error"] == "Validation error"
      assert response["message"] =~ "node_addr is required"
    end

    test "returns 400 when node_addr is not valid JSON" do
      params = %{"node_addr" => "not-valid-json"}

      conn =
        Plug.Test.conn(:post, "/pairing/claim", params)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
        |> Router.call([])

      assert conn.status == 400
      response = Jason.decode!(conn.resp_body)
      assert response["error"] == "Validation error"
      assert response["message"] =~ "node_addr"
    end
  end

  describe "GET /pairing/claim/:code" do
    test "returns node_addr for valid code" do
      # First create a claim
      {:ok, claim} = Pairing.create_claim(@valid_node_addr)

      conn =
        Plug.Test.conn(:get, "/pairing/claim/#{claim.code}")
        |> Router.call([])

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)
      assert response["node_addr"] == @valid_node_addr
    end

    test "returns 404 for non-existent code" do
      conn =
        Plug.Test.conn(:get, "/pairing/claim/NONEXISTENT")
        |> Router.call([])

      assert conn.status == 404
      response = Jason.decode!(conn.resp_body)
      assert response["error"] == "Not found"
    end

    test "returns 404 for expired code (ETS fallback)" do
      # Create an expired claim using ETS directly
      expires_at = System.system_time(:second) - 10
      :ets.insert(:pairing_claims, {"EXPIRE", @valid_node_addr, expires_at})

      conn =
        Plug.Test.conn(:get, "/pairing/claim/EXPIRE")
        |> Router.call([])

      # Returns 404 (not 410) to prevent enumeration
      assert conn.status == 404
      response = Jason.decode!(conn.resp_body)
      assert response["error"] == "Not found"
    end

    test "normalizes code (case insensitive)" do
      {:ok, _claim} = Pairing.create_claim(@valid_node_addr, code: "ABCDEF")

      conn =
        Plug.Test.conn(:get, "/pairing/claim/abcdef")
        |> Router.call([])

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)
      assert response["node_addr"] == @valid_node_addr
    end
  end

  describe "DELETE /pairing/claim/:code" do
    test "deletes existing claim and returns 204" do
      {:ok, claim} = Pairing.create_claim(@valid_node_addr)

      conn =
        Plug.Test.conn(:delete, "/pairing/claim/#{claim.code}")
        |> Router.call([])

      assert conn.status == 204
      assert conn.resp_body == ""

      # Verify claim is deleted
      get_conn =
        Plug.Test.conn(:get, "/pairing/claim/#{claim.code}")
        |> Router.call([])

      assert get_conn.status == 404
    end

    test "returns 204 even for non-existent claim (idempotent)" do
      conn =
        Plug.Test.conn(:delete, "/pairing/claim/NONEXISTENT")
        |> Router.call([])

      assert conn.status == 204
    end

    # Regression guard for T-253: this route previously had no rate limit at
    # all, unlike its POST/GET siblings.
    test "is rate limited after 30 requests from the same caller" do
      for _ <- 1..30 do
        conn = Plug.Test.conn(:delete, "/pairing/claim/NONEXISTENT") |> Router.call([])
        assert conn.status == 204
      end

      conn = Plug.Test.conn(:delete, "/pairing/claim/NONEXISTENT") |> Router.call([])

      assert conn.status == 429
      assert ["60"] = Plug.Conn.get_resp_header(conn, "retry-after")
    end
  end

  describe "v2 sealed claims" do
    setup do
      MetadataRelay.Pairing.init_ets_table()
      :ok
    end

    test "stores a valid sealed claim" do
      params = %{"lookup_key" => String.duplicate("a", 64), "sealed" => "c2VhbGVk"}
      assert {:ok, :no_content} = MetadataRelay.Pairing.Handler.store_sealed_claim(params)
    end

    test "rejects a lookup key that is not 64 hex characters" do
      for bad <- ["short", String.duplicate("z", 64), String.duplicate("a", 63)] do
        params = %{"lookup_key" => bad, "sealed" => "c2VhbGVk"}

        assert {:error, {:validation, _}} =
                 MetadataRelay.Pairing.Handler.store_sealed_claim(params)
      end
    end

    test "rejects a missing or oversized sealed blob" do
      key = String.duplicate("a", 64)

      assert {:error, {:validation, _}} =
               MetadataRelay.Pairing.Handler.store_sealed_claim(%{"lookup_key" => key})

      oversized = String.duplicate("x", 8193)

      assert {:error, {:validation, _}} =
               MetadataRelay.Pairing.Handler.store_sealed_claim(%{
                 "lookup_key" => key,
                 "sealed" => oversized
               })
    end

    test "fetches a stored sealed claim" do
      key = String.duplicate("b", 64)

      {:ok, :no_content} =
        MetadataRelay.Pairing.Handler.store_sealed_claim(%{
          "lookup_key" => key,
          "sealed" => "c2VhbGVk"
        })

      assert {:ok, %{sealed: "c2VhbGVk"}} =
               MetadataRelay.Pairing.Handler.get_sealed_claim(key)
    end

    test "returns not_found for an unknown lookup key" do
      assert {:error, :not_found} =
               MetadataRelay.Pairing.Handler.get_sealed_claim(String.duplicate("c", 64))
    end

    test "deletes a sealed claim" do
      key = String.duplicate("d", 64)

      {:ok, :no_content} =
        MetadataRelay.Pairing.Handler.store_sealed_claim(%{
          "lookup_key" => key,
          "sealed" => "c2VhbGVk"
        })

      assert {:ok, :no_content} = MetadataRelay.Pairing.Handler.delete_sealed_claim(key)
      assert {:error, :not_found} = MetadataRelay.Pairing.Handler.get_sealed_claim(key)
    end
  end

  describe "DELETE /pairing/v2/claim/:lookup_key" do
    # Regression guard for T-257: same missing-rate-limit gap as T-253, on
    # the v2 sealed claim's delete route.
    test "is rate limited after 30 requests from the same caller" do
      key = String.duplicate("e", 64)

      for _ <- 1..30 do
        conn = Plug.Test.conn(:delete, "/pairing/v2/claim/#{key}") |> Router.call([])
        assert conn.status == 204
      end

      conn = Plug.Test.conn(:delete, "/pairing/v2/claim/#{key}") |> Router.call([])

      assert conn.status == 429
      assert ["60"] = Plug.Conn.get_resp_header(conn, "retry-after")
    end
  end

  describe "full pairing flow" do
    test "complete flow: create, get, delete" do
      # Step 1: Server creates claim with its node_addr
      create_params = %{"node_addr" => @valid_node_addr}

      create_conn =
        Plug.Test.conn(:post, "/pairing/claim", create_params)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
        |> Router.call([])

      assert create_conn.status == 200
      %{"claim_code" => code} = Jason.decode!(create_conn.resp_body)

      # Step 2: Client looks up the code to get node_addr
      get_conn =
        Plug.Test.conn(:get, "/pairing/claim/#{code}")
        |> Router.call([])

      assert get_conn.status == 200
      %{"node_addr" => returned_node_addr} = Jason.decode!(get_conn.resp_body)
      assert returned_node_addr == @valid_node_addr

      # Step 3: After successful pairing, server deletes the claim
      delete_conn =
        Plug.Test.conn(:delete, "/pairing/claim/#{code}")
        |> Router.call([])

      assert delete_conn.status == 204

      # Verify claim is gone
      verify_conn =
        Plug.Test.conn(:get, "/pairing/claim/#{code}")
        |> Router.call([])

      assert verify_conn.status == 404
    end
  end
end
