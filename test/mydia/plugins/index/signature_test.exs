defmodule Mydia.Plugins.Index.SignatureTest do
  use ExUnit.Case, async: true

  import Mydia.MinisignFixtures

  alias Mydia.Plugins.Error
  alias Mydia.Plugins.Index.PublicKey
  alias Mydia.Plugins.Index.Signature

  defp cli_key do
    {:ok, key} = Signature.parse_public_key(File.read!(fixture_path("test.pub")))
    key
  end

  describe "against the minisign CLI" do
    test "verifies a prehashed (ED) signature" do
      body = File.read!(fixture_path("catalog.json"))
      sig = File.read!(fixture_path("catalog.json.ED.minisig"))
      assert :ok = Signature.verify(body, sig, cli_key())
    end

    test "verifies a legacy (Ed) signature" do
      body = File.read!(fixture_path("catalog.json"))
      sig = File.read!(fixture_path("catalog.json.Ed.minisig"))
      assert :ok = Signature.verify(body, sig, cli_key())
    end

    test "the fingerprint is the key id minisign prints" do
      [comment | _] = String.split(File.read!(fixture_path("test.pub")), "\n")
      assert comment =~ Signature.fingerprint(cli_key())
      assert Signature.fingerprint(cli_key()) =~ ~r/^[0-9A-F]{16}$/
    end
  end

  describe "parse_public_key/1" do
    test "accepts the bare base64 line" do
      %{public: public} = keypair()
      assert {:ok, %PublicKey{encoded: ^public}} = Signature.parse_public_key(public)
    end

    test "rejects anything that is not an Ed key" do
      assert {:error, %Error{type: :invalid_config}} = Signature.parse_public_key("nope")
      assert {:error, %Error{}} = Signature.parse_public_key(Base.encode64("XX" <> <<0::320>>))
      assert {:error, %Error{}} = Signature.parse_public_key(nil)
    end
  end

  describe "verify/3" do
    setup do
      keys = keypair()
      {:ok, key} = Signature.parse_public_key(keys.public)
      %{keys: keys, key: key}
    end

    test "accepts a body signed by the key", %{keys: keys, key: key} do
      assert :ok = Signature.verify("body", sign("body", keys), key)
      assert :ok = Signature.verify("body", sign("body", keys, alg: "Ed"), key)
    end

    test "rejects a tampered body", %{keys: keys, key: key} do
      assert {:error, %Error{type: :signature_invalid}} =
               Signature.verify("body!", sign("body", keys), key)
    end

    test "rejects a tampered trusted comment", %{keys: keys, key: key} do
      sig =
        "body"
        |> sign(keys, trusted_comment: "original")
        |> String.replace("trusted comment: original", "trusted comment: forged")

      assert {:error, %Error{type: :signature_invalid}} = Signature.verify("body", sig, key)
    end

    test "rejects a signature from another key", %{key: key} do
      assert {:error, %Error{type: :signature_invalid}} =
               Signature.verify("body", sign("body", keypair()), key)
    end

    test "rejects a malformed signature file", %{key: key} do
      assert {:error, %Error{type: :signature_invalid}} = Signature.verify("body", "", key)

      assert {:error, %Error{type: :signature_invalid}} =
               Signature.verify("body", "a\nb\nc\nd", key)
    end
  end
end
