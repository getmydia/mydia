defmodule Mydia.Downloads.BuiltIn.VpnPreflightScriptTest do
  # Runs docker/vpn-preflight.sh under sh. The environment is passed to the
  # child process only, so nothing here touches this VM's environment.
  use ExUnit.Case, async: true

  @script Path.expand("docker/vpn-preflight.sh")

  defp gluetun_env(vars) do
    # Paths go in as positional arguments, so a checkout path with spaces or
    # shell metacharacters survives.
    runner = ~s(. "$1" && run_with_gluetun_env "$2" 65530 key123)

    {out, 0} =
      System.cmd("sh", ["-c", runner, "sh", @script, System.find_executable("env")],
        env: [{"VPN_PREFLIGHT_FUNCTIONS_ONLY", "1"} | vars]
      )

    out
  end

  describe "run_with_gluetun_env" do
    test "passes values with spaces and glob characters unchanged" do
      out =
        gluetun_env([
          {"MYDIA_VPN_SERVICE_PROVIDER", "private internet access"},
          {"MYDIA_VPN_SERVER_CITIES", "New York,Los Angeles"},
          {"MYDIA_VPN_SERVER_HOSTNAMES", "*.example"}
        ])

      lines = String.split(out, "\n")
      assert "SERVER_CITIES=New York,Los Angeles" in lines
      assert "SERVER_HOSTNAMES=*.example" in lines
      assert "VPN_SERVICE_PROVIDER=private internet access" in lines
    end

    test "Mydia's reserved values win over user ones" do
      out =
        gluetun_env([
          {"MYDIA_VPN_SERVICE_PROVIDER", "mullvad"},
          {"MYDIA_VPN_DNS_SERVER", "off"},
          {"MYDIA_VPN_SPLIT_TUNNEL_GID", "1"}
        ])

      lines = String.split(out, "\n")
      assert "DNS_SERVER=on" in lines
      refute "DNS_SERVER=off" in lines
      assert "SPLIT_TUNNEL_GID=65530" in lines

      assert ~s(HTTP_CONTROL_SERVER_AUTH_DEFAULT_ROLE={"auth":"apikey","apikey":"key123"}) in lines
    end

    test "a line inside a multi-line value is not taken for a variable" do
      out =
        gluetun_env([
          {"MYDIA_VPN_SERVICE_PROVIDER", "mullvad"},
          {"MYDIA_VPN_NOTE", "first\nMYDIA_VPN_INJECTED=1"}
        ])

      assert out =~ "NOTE=first\nMYDIA_VPN_INJECTED=1\n"
      refute "INJECTED=1" in String.split(out, "\n")
    end
  end

  describe "rotate_log" do
    @describetag :tmp_dir

    defp rotate(log, max) do
      runner = ~s(. "$1" && rotate_log "$2" "$3")

      {_, 0} =
        System.cmd("sh", ["-c", runner, "sh", @script, log, Integer.to_string(max)],
          env: [{"VPN_PREFLIGHT_FUNCTIONS_ONLY", "1"}]
        )

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

  test "a whitespace-only provider leaves the VPN off" do
    assert {"", 0} =
             System.cmd("sh", [@script],
               env: [{"MYDIA_VPN_SERVICE_PROVIDER", "  \t "}],
               stderr_to_stdout: true
             )
  end
end
