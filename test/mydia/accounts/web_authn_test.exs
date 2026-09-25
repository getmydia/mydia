defmodule Mydia.Accounts.WebAuthnTest do
  use ExUnit.Case, async: true

  alias Mydia.Accounts.{User, WebAuthn}
  alias Mydia.SoftAuthenticator

  @rp_id "mydia.test"
  @origin "https://mydia.test"

  defp user, do: %User{id: Ecto.UUID.generate(), username: "viewer", display_name: nil}

  defp register(authn) do
    challenge = WebAuthn.registration_challenge(@rp_id, @origin)
    options = WebAuthn.registration_options(challenge, user(), [])
    payload = SoftAuthenticator.attest(authn, SoftAuthenticator.ceremony(options, @origin))
    WebAuthn.verify_registration(challenge, payload)
  end

  describe "registration_options/3" do
    test "asks for a discoverable credential bound to the relying party" do
      u = user()
      challenge = WebAuthn.registration_challenge(@rp_id, @origin)

      options =
        WebAuthn.registration_options(challenge, u, [%{id: "abc", transports: ["usb"]}])

      assert options.rp == %{id: @rp_id, name: "Mydia"}
      assert options.challenge == Base.url_encode64(challenge.bytes, padding: false)
      assert options.user.id == Base.url_encode64(Ecto.UUID.dump!(u.id), padding: false)
      assert options.user.name == "viewer"
      assert options.user.displayName == "viewer"
      assert options.attestation == "none"
      assert options.authenticatorSelection.residentKey == "required"
      assert options.authenticatorSelection.userVerification == "preferred"
      assert options.excludeCredentials == [%{type: "public-key", id: "abc", transports: ["usb"]}]
      assert Enum.map(options.pubKeyCredParams, & &1.alg) == [-7, -257]
    end
  end

  describe "verify_registration/2" do
    test "returns the credential for a valid attestation" do
      authn = SoftAuthenticator.new()

      assert {:ok, result} = register(authn)
      assert result.credential_id == SoftAuthenticator.credential_id(authn)
      assert result.sign_count == 0
      assert result.aaguid == nil
      assert result.transports == ["internal"]
      assert %{3 => -7} = result.public_key
    end

    test "rejects an attestation signed for another origin" do
      challenge = WebAuthn.registration_challenge(@rp_id, @origin)
      options = WebAuthn.registration_options(challenge, user(), [])

      payload =
        SoftAuthenticator.attest(
          SoftAuthenticator.new(),
          SoftAuthenticator.ceremony(options, @origin),
          origin: "https://evil.test"
        )

      assert {:error, _} = WebAuthn.verify_registration(challenge, payload)
    end

    test "rejects malformed payloads without raising" do
      challenge = WebAuthn.registration_challenge(@rp_id, @origin)

      assert {:error, _} = WebAuthn.verify_registration(challenge, %{})

      assert {:error, _} =
               WebAuthn.verify_registration(challenge, %{
                 "response" => %{"attestationObject" => "!!", "clientDataJSON" => "!!"}
               })

      bad_type =
        Base.url_encode64(~s({"type":"nope","challenge":"x","origin":"y"}), padding: false)

      assert {:error, _} =
               WebAuthn.verify_registration(challenge, %{
                 "response" => %{"attestationObject" => "AA", "clientDataJSON" => bad_type}
               })
    end
  end

  describe "verify_authentication/4" do
    setup do
      authn = SoftAuthenticator.new()
      {:ok, registered} = register(authn)
      %{authn: authn, registration: registered}
    end

    defp login_ceremony(uv) do
      challenge = WebAuthn.authentication_challenge(@rp_id, @origin, uv)
      options = WebAuthn.authentication_options(challenge, [])
      {challenge, SoftAuthenticator.ceremony(options, @origin)}
    end

    test "accepts a valid assertion and reports the counter", %{authn: authn, registration: reg} do
      {challenge, ceremony} = login_ceremony("required")
      {_authn, payload} = SoftAuthenticator.assert(authn, ceremony)

      assert {:ok, %{sign_count: 1, user_handle: nil}} =
               WebAuthn.verify_authentication(
                 challenge,
                 payload,
                 reg.credential_id,
                 reg.public_key
               )
    end

    test "requires user verification when the challenge does", %{authn: authn, registration: reg} do
      {challenge, ceremony} = login_ceremony("required")
      {_authn, payload} = SoftAuthenticator.assert(authn, ceremony, user_verified: false)

      assert {:error, _} =
               WebAuthn.verify_authentication(
                 challenge,
                 payload,
                 reg.credential_id,
                 reg.public_key
               )

      {challenge, ceremony} = login_ceremony("preferred")
      {_authn, payload} = SoftAuthenticator.assert(authn, ceremony, user_verified: false)

      assert {:ok, _} =
               WebAuthn.verify_authentication(
                 challenge,
                 payload,
                 reg.credential_id,
                 reg.public_key
               )
    end

    test "rejects an assertion for another relying party", %{authn: authn, registration: reg} do
      {challenge, ceremony} = login_ceremony("required")
      {_authn, payload} = SoftAuthenticator.assert(authn, ceremony, rp_id: "other.test")

      assert {:error, _} =
               WebAuthn.verify_authentication(
                 challenge,
                 payload,
                 reg.credential_id,
                 reg.public_key
               )
    end

    test "rejects a payload whose id is not the expected credential", %{
      authn: authn,
      registration: reg
    } do
      {challenge, ceremony} = login_ceremony("required")
      {_authn, payload} = SoftAuthenticator.assert(authn, ceremony)

      assert {:error, _} =
               WebAuthn.verify_authentication(challenge, payload, "someone-else", reg.public_key)
    end

    test "decodes the user handle", %{registration: reg, authn: authn} do
      id = Ecto.UUID.generate()
      authn = %{authn | user_handle: Ecto.UUID.dump!(id)}
      {challenge, ceremony} = login_ceremony("required")
      {_authn, payload} = SoftAuthenticator.assert(authn, ceremony)

      assert {:ok, %{user_handle: handle}} =
               WebAuthn.verify_authentication(
                 challenge,
                 payload,
                 reg.credential_id,
                 reg.public_key
               )

      assert Ecto.UUID.load(handle) == {:ok, id}
    end

    test "credential_id/1 validates the shape" do
      assert {:ok, "abc_-"} = WebAuthn.credential_id(%{"id" => "abc_-"})
      assert :error = WebAuthn.credential_id(%{"id" => ""})
      assert :error = WebAuthn.credential_id(%{"id" => String.duplicate("a", 2000)})
      assert :error = WebAuthn.credential_id(%{})
    end
  end
end
