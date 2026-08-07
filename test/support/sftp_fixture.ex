defmodule Mydia.SftpFixture do
  @moduledoc """
  Starts a real local `:ssh` daemon with SFTP enabled, for tests that need to
  exercise actual `:ssh_sftp` client code rather than mocking it. Bound to
  loopback on an OS-assigned port; each call gets its own throwaway RSA host
  key so daemons never collide across tests.
  """

  require Record

  Record.defrecord(
    :rsa_private_key,
    :RSAPrivateKey,
    Record.extract(:RSAPrivateKey, from_lib: "public_key/include/public_key.hrl")
  )

  @doc """
  Starts a daemon rooted at `root_dir`, authenticating a single user by
  password. Returns `{daemon_ref, port}`. Callers must call
  `:ssh.stop_daemon/1` (typically via `on_exit/1`) when done.
  """
  @spec start(String.t(), String.t(), String.t()) :: {:ssh.daemon_ref(), pos_integer()}
  def start(root_dir, user, password) do
    system_dir = host_key_dir!(root_dir)

    # No `root:` option: `ssh_sftpd`'s chroot rewrites every absolute path
    # to be relative-then-rejoined under `root`, which would turn a real
    # absolute remote path like `root_dir <> "/release.mkv"` into a
    # (nonexistent) doubled-up path. Real seedbox SFTP servers don't jail
    # this way, and `Connection`/`Fetcher` are written against real
    # absolute remote paths, so the fixture only sets `cwd:` (used for
    # relative-path resolution, e.g. `"."`) and leaves absolute paths
    # resolving straight through to the real filesystem.
    sftp_spec = :ssh_sftpd.subsystem_spec(cwd: to_charlist(root_dir))

    {:ok, daemon_ref} =
      :ssh.daemon(
        {127, 0, 0, 1},
        0,
        subsystems: [sftp_spec],
        user_passwords: [{to_charlist(user), to_charlist(password)}],
        system_dir: to_charlist(system_dir)
      )

    {:ok, info} = :ssh.daemon_info(daemon_ref)
    {daemon_ref, Keyword.fetch!(info, :port)}
  end

  @doc """
  Starts a daemon rooted at `root_dir` that authenticates `user` via the
  public key derived from `private_key_pem` (an unencrypted PEM string).
  """
  @spec start_with_key(String.t(), String.t(), String.t()) ::
          {:ssh.daemon_ref(), pos_integer()}
  def start_with_key(root_dir, _user, private_key_pem) do
    system_dir = host_key_dir!(root_dir)
    auth_dir = Path.join(root_dir, ".auth_keys_dir")
    File.mkdir_p!(auth_dir)
    write_authorized_key!(auth_dir, private_key_pem)

    # See the comment in `start/3` — deliberately no `root:` option.
    sftp_spec = :ssh_sftpd.subsystem_spec(cwd: to_charlist(root_dir))

    {:ok, daemon_ref} =
      :ssh.daemon(
        {127, 0, 0, 1},
        0,
        subsystems: [sftp_spec],
        system_dir: to_charlist(system_dir),
        user_dir_fun: fn _remote_user_name -> to_charlist(auth_dir) end,
        pwdfun: fn _user, _password -> false end
      )

    {:ok, info} = :ssh.daemon_info(daemon_ref)
    {daemon_ref, Keyword.fetch!(info, :port)}
  end

  defp host_key_dir!(root_dir) do
    dir = Path.join(root_dir, ".ssh_host_keys")
    File.mkdir_p!(dir)

    key = :public_key.generate_key({:rsa, 2048, 65_537})
    entry = :public_key.pem_entry_encode(:RSAPrivateKey, key)
    pem = :public_key.pem_encode([entry])
    File.write!(Path.join(dir, "ssh_host_rsa_key"), pem)

    dir
  end

  # OTP's default server-side key handling reads the CLIENT's trusted public
  # keys from `<user_dir>/authorized_keys`, in the standard OpenSSH
  # authorized_keys line format. `:ssh_file.encode/2` (the successor to the
  # deprecated `:public_key.ssh_encode/2` on this OTP version) derives that
  # line straight from the private key's own public components, so the
  # daemon trusts exactly the key `Seedbox.Connection`/`Fetcher` will
  # present — no separate keypair to keep in sync.
  defp write_authorized_key!(auth_dir, private_key_pem) do
    [pem_entry] = :public_key.pem_decode(private_key_pem)
    priv = :public_key.pem_entry_decode(pem_entry)

    public_key =
      {:RSAPublicKey, rsa_private_key(priv, :modulus), rsa_private_key(priv, :publicExponent)}

    line = :ssh_file.encode([{public_key, []}], :auth_keys)
    File.write!(Path.join(auth_dir, "authorized_keys"), line)
  end
end
