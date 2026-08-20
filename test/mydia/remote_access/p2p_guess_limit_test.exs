defmodule Mydia.RemoteAccess.P2pGuessLimitTest do
  use Mydia.DataCase, async: false

  import Mydia.AccountsFixtures

  alias Mydia.RemoteAccess
  alias Mydia.RemoteAccess.ClaimRateLimiter

  setup do
    bypass = Bypass.open()

    Bypass.stub(bypass, "POST", "/pairing/v2/claim", fn conn ->
      Plug.Conn.resp(conn, 204, "")
    end)

    ClaimRateLimiter.reset_rate_limit("p2p:pairing")

    {:ok,
     bypass: bypass,
     user: user_fixture(),
     pairing_opts: [
       relay_url: "http://localhost:#{bypass.port}",
       node_addr: ~s({"id":"test-node"}),
       instance_id: "test-instance"
     ]}
  end

  test "rejects without consuming budget when no claim is active" do
    assert {:error, :not_found} = RemoteAccess.validate_claim_code_from_peer("AAAAAA")

    # 50 attempts against an empty claim set must not exhaust the 10-guess
    # budget, otherwise an attacker could pre-drain it before a real pairing.
    for _ <- 1..50 do
      assert {:error, :not_found} = RemoteAccess.validate_claim_code_from_peer("AAAAAA")
    end

    assert :ok =
             ClaimRateLimiter.check_and_record("p2p:pairing",
               max_attempts: 10,
               window_seconds: 300
             )
  end

  test "blocks after ten wrong guesses against a live claim", %{
    user: user,
    pairing_opts: pairing_opts
  } do
    {:ok, claim} = RemoteAccess.generate_claim_code(user.id, pairing_opts)

    for _ <- 1..10 do
      assert {:error, :not_found} = RemoteAccess.validate_claim_code_from_peer("ZZZZZZ")
    end

    # The correct code no longer works: the live claim is burned.
    assert {:error, :too_many_attempts} =
             RemoteAccess.validate_claim_code_from_peer(claim.code)
  end

  test "a fresh code clears the counter", %{user: user, pairing_opts: pairing_opts} do
    {:ok, _burned} = RemoteAccess.generate_claim_code(user.id, pairing_opts)

    for _ <- 1..10 do
      RemoteAccess.validate_claim_code_from_peer("ZZZZZZ")
    end

    {:ok, fresh} = RemoteAccess.generate_claim_code(user.id, pairing_opts)

    assert {:ok, claim} = RemoteAccess.validate_claim_code_from_peer(fresh.code)
    assert claim.code == fresh.code
  end

  test "a correct guess resets the counter", %{user: user, pairing_opts: pairing_opts} do
    {:ok, claim} = RemoteAccess.generate_claim_code(user.id, pairing_opts)

    for _ <- 1..5 do
      RemoteAccess.validate_claim_code_from_peer("ZZZZZZ")
    end

    assert {:ok, _} = RemoteAccess.validate_claim_code_from_peer(claim.code)

    for _ <- 1..9 do
      assert {:error, _} = RemoteAccess.validate_claim_code_from_peer("ZZZZZZ")
    end
  end
end
