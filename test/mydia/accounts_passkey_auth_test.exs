defmodule Mydia.AccountsPasskeyAuthTest do
  use Mydia.DataCase, async: true

  import Mydia.AccountsFixtures
  import ExUnit.CaptureLog

  alias Mydia.Accounts
  alias Mydia.Accounts.Passkey
  alias Mydia.Repo
  alias Mydia.SoftAuthenticator

  @rp_id "mydia.test"
  @origin "https://mydia.test"

  setup do
    user = user_fixture()
    Map.put(passkey_fixture(user), :user, user)
  end

  defp login_ceremony(user \\ nil, rp_id \\ @rp_id, origin \\ @origin) do
    {challenge, options} = Accounts.passkey_authentication_challenge(rp_id, origin, user)
    {challenge, options, SoftAuthenticator.ceremony(options, origin)}
  end

  test "signs in the passkey's owner and records the use", ctx do
    {challenge, _options, ceremony} = login_ceremony()
    {_authn, payload} = SoftAuthenticator.assert(ctx.authenticator, ceremony)

    assert {:ok, user} = Accounts.authenticate_passkey(challenge, payload)
    assert user.id == ctx.user.id

    passkey = Repo.get!(Passkey, ctx.passkey.id)
    assert passkey.sign_count == 1
    assert passkey.last_used_at
  end

  test "passwordless options demand user verification and list no credentials" do
    {challenge, options, _ceremony} = login_ceremony()
    assert challenge.user_verification == "required"
    assert options.userVerification == "required"
    assert options.allowCredentials == []
  end

  test "second-factor options list only the user's passkeys on this host", ctx do
    passkey_fixture(ctx.user, rp_id: "other.test")
    {challenge, options, _ceremony} = login_ceremony(ctx.user)

    assert challenge.user_verification == "preferred"
    assert Enum.map(options.allowCredentials, & &1.id) == [ctx.passkey.credential_id]
  end

  test "rejects an assertion without user verification for passwordless sign-in", ctx do
    {challenge, _options, ceremony} = login_ceremony()

    {_authn, payload} =
      SoftAuthenticator.assert(ctx.authenticator, ceremony, user_verified: false)

    assert {:error, :invalid_passkey} = Accounts.authenticate_passkey(challenge, payload)
  end

  test "rejects a passkey registered on another host", ctx do
    {challenge, _options, ceremony} = login_ceremony(nil, "other.test", "https://other.test")
    {_authn, payload} = SoftAuthenticator.assert(ctx.authenticator, ceremony)

    assert {:error, :invalid_passkey} = Accounts.authenticate_passkey(challenge, payload)
  end

  test "rejects an unknown credential and malformed payloads" do
    {challenge, _options, ceremony} = login_ceremony()
    {_authn, payload} = SoftAuthenticator.assert(SoftAuthenticator.new(), ceremony)

    assert {:error, :invalid_passkey} = Accounts.authenticate_passkey(challenge, payload)
    assert {:error, :invalid_passkey} = Accounts.authenticate_passkey(challenge, %{})
    assert {:error, :invalid_passkey} = Accounts.authenticate_passkey(challenge, %{"id" => 5})
  end

  test "rejects a user handle that belongs to someone else", ctx do
    other = user_fixture()
    authn = SoftAuthenticator.for_user(ctx.authenticator, other)
    {challenge, _options, ceremony} = login_ceremony()
    {_authn, payload} = SoftAuthenticator.assert(authn, ceremony)

    assert {:error, :invalid_passkey} = Accounts.authenticate_passkey(challenge, payload)
  end

  test "rejects a counter that goes backwards and logs it", ctx do
    {challenge, _options, ceremony} = login_ceremony()
    {authn, payload} = SoftAuthenticator.assert(ctx.authenticator, ceremony, sign_count: 5)
    assert {:ok, _} = Accounts.authenticate_passkey(challenge, payload)

    {challenge, _options, ceremony} = login_ceremony()
    {_authn, payload} = SoftAuthenticator.assert(authn, ceremony, sign_count: 3)

    log =
      capture_log(fn ->
        assert {:error, :invalid_passkey} = Accounts.authenticate_passkey(challenge, payload)
      end)

    assert log =~ "sign count"
  end

  test "rejects a zero counter after the stored counter advanced", ctx do
    {challenge, _options, ceremony} = login_ceremony()
    {authn, payload} = SoftAuthenticator.assert(ctx.authenticator, ceremony, sign_count: 5)
    assert {:ok, _} = Accounts.authenticate_passkey(challenge, payload)

    {challenge, _options, ceremony} = login_ceremony()
    {_authn, payload} = SoftAuthenticator.assert(authn, ceremony, sign_count: 0)

    assert {:error, :invalid_passkey} = Accounts.authenticate_passkey(challenge, payload)
  end

  test "accepts authenticators that always report a zero counter", ctx do
    for _ <- 1..2 do
      {challenge, _options, ceremony} = login_ceremony()
      {_authn, payload} = SoftAuthenticator.assert(ctx.authenticator, ceremony, sign_count: 0)
      assert {:ok, _} = Accounts.authenticate_passkey(challenge, payload)
    end
  end

  describe "verify_second_factor/2 with a passkey" do
    test "accepts the user's own passkey", ctx do
      {challenge, _options, ceremony} = login_ceremony(ctx.user)

      {_authn, payload} =
        SoftAuthenticator.assert(ctx.authenticator, ceremony, user_verified: false)

      assert :ok = Accounts.verify_second_factor(ctx.user, {:passkey, challenge, payload})
    end

    test "refuses another user's passkey without touching it", ctx do
      other = user_fixture()
      {challenge, _options, ceremony} = login_ceremony(other)
      {_authn, payload} = SoftAuthenticator.assert(ctx.authenticator, ceremony)

      assert {:error, :invalid_code} =
               Accounts.verify_second_factor(other, {:passkey, challenge, payload})

      assert Repo.get!(Passkey, ctx.passkey.id).sign_count == 0
    end
  end
end
