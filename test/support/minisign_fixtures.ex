defmodule Mydia.MinisignFixtures do
  @moduledoc """
  Keypairs and signatures in the minisign format, made with `:crypto`, so tests
  can sign catalogs without the CLI. `test/support/fixtures/minisign/` holds
  CLI-made fixtures that pin this signer to the real tool.
  """

  @fixture_dir Path.expand("fixtures/minisign", __DIR__)

  def fixture_path(name), do: Path.join(@fixture_dir, name)

  def keypair do
    {pub, secret} = :crypto.generate_key(:eddsa, :ed25519)
    key_id = :crypto.strong_rand_bytes(8)
    %{public: Base.encode64("Ed" <> key_id <> pub), secret: secret, key_id: key_id}
  end

  def sign(body, %{secret: secret, key_id: key_id}, opts \\ []) do
    alg = Keyword.get(opts, :alg, "ED")
    trusted = Keyword.get(opts, :trusted_comment, "timestamp:0")
    message = if alg == "ED", do: :crypto.hash(:blake2b, body), else: body
    sig = :crypto.sign(:eddsa, :none, message, [secret, :ed25519])
    global = :crypto.sign(:eddsa, :none, sig <> trusted, [secret, :ed25519])

    "untrusted comment: signature from mydia test key\n" <>
      Base.encode64(alg <> key_id <> sig) <>
      "\ntrusted comment: " <> trusted <> "\n" <> Base.encode64(global) <> "\n"
  end
end
