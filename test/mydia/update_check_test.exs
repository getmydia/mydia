defmodule Mydia.UpdateCheckTest do
  # Not async: the last answer lives in :persistent_term, which is global.
  use Mydia.DataCase, async: false

  alias Mydia.Settings
  alias Mydia.UpdateCheck

  setup do
    UpdateCheck.forget()
    on_exit(&UpdateCheck.forget/0)
    :ok
  end

  defp env(vars), do: &Map.get(vars, &1)

  defp relay_url(bypass), do: "http://localhost:#{bypass.port}"

  defp newer_version do
    {:ok, current} = Version.parse(to_string(Application.spec(:mydia, :vsn)))
    "#{current.major + 1}.0.0"
  end

  defp expect_check(bypass, response) do
    test_pid = self()

    Bypass.expect_once(bypass, "POST", "/update-check", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:sent, Jason.decode!(body)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(response))
    end)
  end

  defp disable_in_settings do
    {:ok, _} =
      Settings.upsert_config_setting(%{
        key: "update_check.enabled",
        value: "false",
        category: :general
      })
  end

  describe "payload/0" do
    test "sends exactly the install id, version, architecture and database" do
      payload = UpdateCheck.payload()

      assert Map.keys(payload) |> Enum.sort() == ["arch", "db", "install_id", "version"]
      assert payload["install_id"] =~ ~r/\A[0-9a-f]{64}\z/
      assert payload["version"] == to_string(Application.spec(:mydia, :vsn))
      assert payload["db"] == Atom.to_string(Mydia.DB.adapter_type())
    end

    test "keeps the same install id across checks" do
      assert UpdateCheck.payload()["install_id"] == UpdateCheck.payload()["install_id"]
    end
  end

  describe "run/1" do
    test "reports a newer release once the relay names one" do
      bypass = Bypass.open()
      latest = newer_version()
      expect_check(bypass, %{latest_version: latest, release_url: "https://example.test/r"})

      assert {:ok, %{version: ^latest}} =
               UpdateCheck.run(relay_url: relay_url(bypass), getenv: env(%{}))

      assert_received {:sent, %{"install_id" => _, "version" => _, "arch" => _, "db" => _}}
      assert %{version: ^latest, url: "https://example.test/r"} = UpdateCheck.available_update()
    end

    test "drops a release URL that is not https" do
      bypass = Bypass.open()

      expect_check(bypass, %{
        latest_version: newer_version(),
        release_url: "javascript:alert(document.cookie)"
      })

      assert {:ok, %{url: nil}} = UpdateCheck.run(relay_url: relay_url(bypass), getenv: env(%{}))
    end

    test "reports nothing when the relay's release is not newer" do
      bypass = Bypass.open()
      current = to_string(Application.spec(:mydia, :vsn))
      expect_check(bypass, %{latest_version: current, release_url: nil})

      assert {:ok, _} = UpdateCheck.run(relay_url: relay_url(bypass), getenv: env(%{}))
      assert UpdateCheck.available_update() == nil
    end

    test "reports nothing when the relay knows no release" do
      bypass = Bypass.open()
      expect_check(bypass, %{latest_version: nil, release_url: nil})

      assert {:ok, nil} = UpdateCheck.run(relay_url: relay_url(bypass), getenv: env(%{}))
      assert UpdateCheck.available_update() == nil
    end

    test "sends nothing when the environment turns it off" do
      bypass = Bypass.open()

      assert :disabled =
               UpdateCheck.run(
                 relay_url: relay_url(bypass),
                 getenv: env(%{"UPDATE_CHECK_ENABLED" => "false"})
               )
    end

    test "sends nothing when the admin toggle turns it off" do
      bypass = Bypass.open()
      disable_in_settings()

      assert :disabled = UpdateCheck.run(relay_url: relay_url(bypass), getenv: env(%{}))
    end

    test "survives an unreachable relay" do
      bypass = Bypass.open()
      Bypass.down(bypass)

      assert {:error, _} = UpdateCheck.run(relay_url: relay_url(bypass), getenv: env(%{}))
      assert UpdateCheck.available_update() == nil
    end
  end

  describe "enabled?/1" do
    test "is on by default" do
      assert UpdateCheck.enabled?(env(%{}))
    end

    test "the environment wins over the admin toggle" do
      disable_in_settings()

      refute UpdateCheck.enabled?(env(%{}))
      assert UpdateCheck.enabled?(env(%{"UPDATE_CHECK_ENABLED" => "true"}))
    end

    test "an empty environment variable counts as unset" do
      assert UpdateCheck.enabled?(env(%{"UPDATE_CHECK_ENABLED" => ""}))
    end
  end

  test "turning the check off hides an update already found" do
    bypass = Bypass.open()
    expect_check(bypass, %{latest_version: newer_version(), release_url: nil})
    {:ok, _} = UpdateCheck.run(relay_url: relay_url(bypass), getenv: env(%{}))

    disable_in_settings()

    assert UpdateCheck.available_update() == nil
  end
end
