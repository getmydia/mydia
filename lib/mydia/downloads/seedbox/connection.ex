defmodule Mydia.Downloads.Seedbox.Connection do
  @moduledoc """
  Opens an `:ssh_sftp` channel from a `remote_fetch` config map (password or
  SSH-key auth, `Mydia.Settings.DownloadClientConfig.connection_settings`
  `"remote_fetch"` shape). Shared by `Seedbox.Fetcher` (the transfer engine)
  and the admin UI's "Test SFTP Connection" action, so both speak to a
  seedbox the same way.

  SSH-key auth is implemented by writing the key to a throwaway directory
  under every conventional filename OTP's default `ssh_file` key callback
  recognizes (`id_rsa`, `id_ed25519`, `id_ecdsa`, `id_dsa`) and pointing
  `user_dir` at it, rather than a custom `ssh_client_key_api` callback
  module — this reuses OTP's own (already correct) key-format detection and
  signing instead of reimplementing it.
  """

  @conventional_key_filenames ~w(id_rsa id_ed25519 id_ecdsa id_dsa)

  @doc """
  Opens a channel. Returns `{:ok, channel, cleanup}` where `cleanup` is a
  0-arity function the caller MUST invoke (in an `after` block) once done —
  it stops the channel and removes any temporary key material written to
  disk for SSH-key auth. `silently_accept_hosts: true` is used deliberately:
  the host is explicitly operator-configured (this isn't discovering an
  unknown host), matching the trust posture of most seedbox sync tools.
  """
  @spec open(map()) :: {:ok, pid(), (-> :ok)} | {:error, term()}
  def open(%{"auth_method" => "password"} = rf) do
    connect(rf, password_opts(rf), nil)
  end

  def open(%{"auth_method" => "ssh_key"} = rf) do
    key_dir = materialize_key_dir!(rf)
    connect(rf, key_opts(rf, key_dir), key_dir)
  end

  defp password_opts(rf) do
    [
      user: to_charlist(Map.fetch!(rf, "username")),
      password: to_charlist(Map.fetch!(rf, "password")),
      silently_accept_hosts: true,
      save_accepted_host: false
    ]
  end

  defp key_opts(rf, key_dir) do
    [
      user: to_charlist(Map.fetch!(rf, "username")),
      user_dir: to_charlist(key_dir),
      silently_accept_hosts: true,
      save_accepted_host: false
    ]
  end

  defp connect(rf, ssh_opts, key_dir) do
    host = to_charlist(Map.fetch!(rf, "host"))
    port = Map.get(rf, "port", 22)

    case :ssh_sftp.start_channel(host, port, ssh_opts) do
      {:ok, channel, _connection_ref} -> {:ok, channel, cleanup(channel, key_dir)}
      {:ok, channel} -> {:ok, channel, cleanup(channel, key_dir)}
      {:error, reason} -> cleanup_key_dir(key_dir) && {:error, reason}
    end
  end

  defp cleanup(channel, key_dir) do
    fn ->
      :ssh_sftp.stop_channel(channel)
      cleanup_key_dir(key_dir)
      :ok
    end
  end

  defp materialize_key_dir!(rf) do
    private_key_pem =
      decrypt_private_key(Map.fetch!(rf, "private_key"), Map.get(rf, "passphrase"))

    dir =
      Path.join(
        System.tmp_dir!(),
        "seedbox-ssh-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(dir)

    for filename <- @conventional_key_filenames do
      path = Path.join(dir, filename)
      File.write!(path, private_key_pem)
      File.chmod!(path, 0o600)
    end

    dir
  end

  defp decrypt_private_key(pem, passphrase) when passphrase in [nil, ""], do: pem

  defp decrypt_private_key(pem, passphrase) do
    [entry] = :public_key.pem_decode(pem)
    key = :public_key.pem_entry_decode(entry, to_charlist(passphrase))
    reencoded = :public_key.pem_entry_encode(elem(entry, 0), key)
    :public_key.pem_encode([reencoded])
  end

  defp cleanup_key_dir(nil), do: true
  defp cleanup_key_dir(dir), do: File.rm_rf!(dir) && true
end
