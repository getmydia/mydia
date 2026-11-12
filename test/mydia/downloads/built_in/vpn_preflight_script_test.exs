defmodule Mydia.Downloads.BuiltIn.VpnPreflightScriptTest do
  # Runs docker/vpn-preflight.sh under sh. The environment is passed to the
  # child process only, so nothing here touches this VM's environment.
  use ExUnit.Case, async: true

  @script Path.expand("docker/vpn-preflight.sh")
  @auth_toml "/run/mydia-vpn/auth.toml"

  # Runs `runner` with the script's functions loaded. Paths go in as
  # positional arguments, so a checkout path with spaces or shell
  # metacharacters survives. VPN_AS_MYDIA is `env`, a no-op prefix, so the
  # reads and writes the script does as mydia run as the test user instead of
  # through su-exec.
  defp sh(runner, args, vars \\ []) do
    System.cmd("sh", ["-c", ~s(. "$1" && ) <> runner, "sh", @script | args],
      env: isolated_env([{"VPN_PREFLIGHT_FUNCTIONS_ONLY", "1"}, {"VPN_AS_MYDIA", "env"} | vars])
    )
  end

  # The child inherits this VM's environment, so a MYDIA_VPN_* or
  # MYDIA_TORRENT_* variable set where the suite runs would change what the
  # script decides. Every such variable `vars` does not set is unset (a nil
  # value unsets it in the child only).
  defp isolated_env(vars) do
    set = MapSet.new(vars, fn {name, _value} -> name end)

    inherited =
      for {name, _value} <- System.get_env(),
          String.starts_with?(name, ["MYDIA_VPN_", "MYDIA_TORRENT_", "VPN_"]),
          not MapSet.member?(set, name),
          do: {name, nil}

    inherited ++ vars
  end

  defp gluetun_env(vars, settings \\ "/nonexistent/settings.env") do
    {out, 0} =
      sh(
        ~s(run_with_gluetun_env "$2" 65530 "$3"),
        [System.find_executable("env"), settings],
        vars
      )

    String.split(out, "\n")
  end

  defp settings_file(dir, content) do
    path = Path.join(dir, "settings.env")
    File.write!(path, content)
    path
  end

  # The value gluetun sees: under `env -i` the last occurrence wins.
  defp last_value(lines, key) do
    prefix = key <> "="

    lines
    |> Enum.filter(&String.starts_with?(&1, prefix))
    |> List.last()
    |> case do
      nil -> nil
      line -> String.replace_prefix(line, prefix, "")
    end
  end

  describe "run_with_gluetun_env" do
    test "passes values with spaces and glob characters unchanged" do
      lines =
        gluetun_env([
          {"MYDIA_VPN_SERVICE_PROVIDER", "private internet access"},
          {"MYDIA_VPN_SERVER_CITIES", "New York,Los Angeles"},
          {"MYDIA_VPN_SERVER_HOSTNAMES", "*.example"}
        ])

      assert "SERVER_CITIES=New York,Los Angeles" in lines
      assert "SERVER_HOSTNAMES=*.example" in lines
      assert "VPN_SERVICE_PROVIDER=private internet access" in lines
    end

    test "Mydia's reserved values win over user ones" do
      lines =
        gluetun_env([
          {"MYDIA_VPN_SERVICE_PROVIDER", "mullvad"},
          {"MYDIA_VPN_DNS_SERVER", "off"},
          {"MYDIA_VPN_SPLIT_TUNNEL_GID", "1"},
          {"MYDIA_VPN_HTTP_CONTROL_SERVER_AUTH_CONFIG_FILEPATH", "/tmp/evil.toml"},
          {"MYDIA_VPN_HTTP_CONTROL_SERVER_AUTH_DEFAULT_ROLE", ~s({"auth":"none"})}
        ])

      assert last_value(lines, "DNS_SERVER") == "on"
      assert last_value(lines, "SPLIT_TUNNEL_GID") == "65530"
      assert last_value(lines, "HTTP_CONTROL_SERVER_AUTH_CONFIG_FILEPATH") == @auth_toml
      assert last_value(lines, "HTTP_CONTROL_SERVER_AUTH_DEFAULT_ROLE") == "{}"
    end

    test "a line inside a multi-line value is not taken for a variable" do
      out =
        [
          {"MYDIA_VPN_SERVICE_PROVIDER", "mullvad"},
          {"MYDIA_VPN_NOTE", "first\nMYDIA_VPN_INJECTED=1"}
        ]
        |> gluetun_env()
        |> Enum.join("\n")

      assert out =~ "NOTE=first\nMYDIA_VPN_INJECTED=1\n"
      refute "INJECTED=1" in String.split(out, "\n")
    end

    @tag :tmp_dir
    test "passes allowlisted file keys byte for byte and drops the rest", %{tmp_dir: dir} do
      path =
        settings_file(dir, """
        VPN_ENABLED=true
        VPN_SERVICE_PROVIDER=mullvad
        OPENVPN_PASSWORD=p=q $x 'y"
        FIREWALL=off
        """)

      lines = gluetun_env([], path)
      assert "VPN_SERVICE_PROVIDER=mullvad" in lines
      assert ~s(OPENVPN_PASSWORD=p=q $x 'y") in lines
      refute "FIREWALL=off" in lines
      refute Enum.any?(lines, &String.starts_with?(&1, "VPN_ENABLED="))
    end

    @tag :tmp_dir
    test "env beats the file", %{tmp_dir: dir} do
      path = settings_file(dir, "VPN_ENABLED=true\nSERVER_COUNTRIES=Germany\n")
      lines = gluetun_env([{"MYDIA_VPN_SERVER_COUNTRIES", "Canada"}], path)
      assert last_value(lines, "SERVER_COUNTRIES") == "Canada"
    end

    @tag :tmp_dir
    test "a blank env value does not override the file", %{tmp_dir: dir} do
      path =
        settings_file(dir, "VPN_ENABLED=true\nVPN_SERVICE_PROVIDER=mullvad\nSERVER_CITIES=Oslo\n")

      lines =
        gluetun_env(
          [{"MYDIA_VPN_SERVICE_PROVIDER", " \t"}, {"MYDIA_VPN_SERVER_CITIES", " "}],
          path
        )

      assert last_value(lines, "VPN_SERVICE_PROVIDER") == "mullvad"
      assert last_value(lines, "SERVER_CITIES") == "Oslo"
    end
  end

  describe "read_settings_file" do
    @describetag :tmp_dir

    defp read_settings(path) do
      {out, 0} =
        sh(
          ~s(read_settings_file "$2" && printf '%s|%s|%s' "$settings_enabled" "$dropped" "$invalid"),
          [path]
        )

      out
    end

    test "reports dropped keys once each and the enable switch", %{tmp_dir: dir} do
      path = settings_file(dir, "VPN_ENABLED=true\nFIREWALL=off\nDNS_SERVER=off\nFIREWALL=x\n")
      assert read_settings(path) == "true|FIREWALL,DNS_SERVER|0"
    end

    test "a line that is not a key is counted, never echoed", %{tmp_dir: dir} do
      path = settings_file(dir, "root:$6$abc:19000:0:::\nlower=1\nnoequals\nVPN_ENABLED=false\n")
      assert read_settings(path) == "false||3"
    end

    test "a missing file disables the VPN", %{tmp_dir: dir} do
      assert read_settings(Path.join(dir, "absent")) == "false||0"
    end

    test "a last line without a newline still counts", %{tmp_dir: dir} do
      assert read_settings(settings_file(dir, "VPN_ENABLED=true")) == "true||0"
    end
  end

  describe "snapshot_settings" do
    @describetag :tmp_dir

    test "copies the file and prints its sha256", %{tmp_dir: dir} do
      src = settings_file(dir, "VPN_ENABLED=true\n")
      snap = Path.join(dir, "snap")
      {out, 0} = sh(~s(snapshot_settings "$2" "$3"), [src, snap])

      assert out == :crypto.hash(:sha256, "VPN_ENABLED=true\n") |> Base.encode16(case: :lower)
      assert File.read!(snap) == "VPN_ENABLED=true\n"
    end

    test "prints none and leaves an empty snapshot for a missing file", %{tmp_dir: dir} do
      snap = Path.join(dir, "snap")
      File.write!(snap, "VPN_ENABLED=true\n")
      {out, 0} = sh(~s(snapshot_settings "$2" "$3"), [Path.join(dir, "absent"), snap])

      assert out == "none"
      assert File.read!(snap) == ""
    end
  end

  describe "write_auth_toml" do
    @describetag :tmp_dir

    test "writes one apikey role limited to the three read routes", %{tmp_dir: dir} do
      path = Path.join(dir, "auth.toml")
      {_, 0} = sh(~s(write_auth_toml "$2" "$3"), [path, "k3y"])

      assert File.read!(path) == """
             [[roles]]
             name = "mydia"
             auth = "apikey"
             apikey = "k3y"
             routes = ["GET /v1/vpn/status", "GET /v1/publicip/ip", "GET /v1/portforward"]
             """

      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    end
  end

  describe "write_loop_status" do
    @describetag :tmp_dir

    test "writes the hash and dropped keys", %{tmp_dir: dir} do
      path = Path.join(dir, "loop-status")
      {_, 0} = sh(~s(write_loop_status "$2" abc "FIREWALL,DNS_SERVER"), [path])
      assert File.read!(path) == "hash=abc\ndropped=FIREWALL,DNS_SERVER\n"
      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o644
    end

    test "adds the invalid count only when nonzero", %{tmp_dir: dir} do
      path = Path.join(dir, "loop-status")
      {_, 0} = sh(~s(write_loop_status "$2" none "" 0), [path])
      assert File.read!(path) == "hash=none\ndropped=\n"

      {_, 0} = sh(~s(write_loop_status "$2" none "" 3), [path])
      assert File.read!(path) == "hash=none\ndropped=\ninvalid=3\n"
    end
  end

  describe "vpn_wanted" do
    defp wanted(enabled, vars) do
      {out, 0} = sh(~s(vpn_wanted "$2"), [enabled], vars)
      out
    end

    test "the file or a non-blank env provider turns the VPN on" do
      assert wanted("true", []) == "1"
      assert wanted("false", [{"MYDIA_VPN_SERVICE_PROVIDER", "mullvad"}]) == "1"
      assert wanted("false", []) == "0"
      assert wanted("false", [{"MYDIA_VPN_SERVICE_PROVIDER", "  \t "}]) == "0"
    end
  end

  describe "loop_action" do
    defp action(running, wanted, started_hash, hash) do
      {out, 0} = sh(~s(loop_action "$2" "$3" "$4" "$5"), [running, wanted, started_hash, hash])
      out
    end

    test "starts, restarts on a new hash, stops, or idles" do
      assert action("0", "1", "", "a") == "start"
      assert action("1", "1", "a", "a") == "none"
      assert action("1", "1", "a", "b") == "restart"
      assert action("1", "0", "a", "b") == "stop"
      assert action("0", "0", "", "a") == "none"
    end
  end

  describe "rotate_log" do
    @describetag :tmp_dir

    defp rotate(log, max) do
      {_, 0} = sh(~s(rotate_log "$2" "$3"), [log, Integer.to_string(max)])
      :ok
    end

    test "moves a log over the limit aside, replacing the previous one", %{tmp_dir: dir} do
      log = Path.join(dir, "gluetun.log")
      File.write!(log <> ".1", "older")
      File.write!(log, String.duplicate("x", 11))

      rotate(log, 10)

      refute File.exists?(log)
      assert File.read!(log <> ".1") == String.duplicate("x", 11)
    end

    test "leaves a log within the limit, or a missing one, alone", %{tmp_dir: dir} do
      log = Path.join(dir, "gluetun.log")
      rotate(log, 10)
      refute File.exists?(log <> ".1")

      File.write!(log, "short")
      rotate(log, 10)
      assert File.read!(log) == "short"
      refute File.exists?(log <> ".1")
    end
  end

  test "the client turned off in env leaves the VPN off" do
    assert {out, 0} =
             System.cmd("sh", [@script],
               env: isolated_env([{"MYDIA_TORRENT_ENABLED", " Off "}]),
               stderr_to_stdout: true
             )

    assert out =~ "MYDIA_TORRENT_ENABLED"
  end
end
