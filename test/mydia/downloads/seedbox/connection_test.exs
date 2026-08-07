defmodule Mydia.Downloads.Seedbox.ConnectionTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.Seedbox.Connection
  alias Mydia.SftpFixture

  setup do
    root = Path.join(System.tmp_dir!(), "sftp_conn_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "opens and cleans up a password-authenticated channel", %{root: root} do
    {daemon_ref, port} = SftpFixture.start(root, "seeduser", "seedpass")
    on_exit(fn -> :ssh.stop_daemon(daemon_ref) end)

    remote_fetch = %{
      "auth_method" => "password",
      "host" => "127.0.0.1",
      "port" => port,
      "username" => "seeduser",
      "password" => "seedpass"
    }

    assert {:ok, channel, cleanup} = Connection.open(remote_fetch)
    assert {:ok, _info} = :ssh_sftp.read_file_info(channel, ~c".")
    assert :ok = cleanup.()
  end

  test "opens a channel when port is a string, as stored by the admin UI form", %{root: root} do
    {daemon_ref, port} = SftpFixture.start(root, "seeduser", "seedpass")
    on_exit(fn -> :ssh.stop_daemon(daemon_ref) end)

    remote_fetch = %{
      "auth_method" => "password",
      "host" => "127.0.0.1",
      "port" => to_string(port),
      "username" => "seeduser",
      "password" => "seedpass"
    }

    assert {:ok, channel, cleanup} = Connection.open(remote_fetch)
    assert {:ok, _info} = :ssh_sftp.read_file_info(channel, ~c".")
    assert :ok = cleanup.()
  end

  test "returns an error for a wrong password", %{root: root} do
    {daemon_ref, port} = SftpFixture.start(root, "seeduser", "seedpass")
    on_exit(fn -> :ssh.stop_daemon(daemon_ref) end)

    remote_fetch = %{
      "auth_method" => "password",
      "host" => "127.0.0.1",
      "port" => port,
      "username" => "seeduser",
      "password" => "wrong"
    }

    assert {:error, _reason} = Connection.open(remote_fetch)
  end

  test "opens a channel with SSH-key auth and removes the temp key material after cleanup", %{
    root: root
  } do
    private_key_pem = generate_test_private_key_pem()
    {daemon_ref, port} = SftpFixture.start_with_key(root, "seeduser", private_key_pem)
    on_exit(fn -> :ssh.stop_daemon(daemon_ref) end)

    remote_fetch = %{
      "auth_method" => "ssh_key",
      "host" => "127.0.0.1",
      "port" => port,
      "username" => "seeduser",
      "private_key" => private_key_pem
    }

    assert {:ok, channel, cleanup} = Connection.open(remote_fetch)
    assert {:ok, _info} = :ssh_sftp.read_file_info(channel, ~c".")
    assert :ok = cleanup.()
  end

  defp generate_test_private_key_pem do
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    entry = :public_key.pem_entry_encode(:RSAPrivateKey, key)
    :public_key.pem_encode([entry])
  end
end
