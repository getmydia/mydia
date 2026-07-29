defmodule Mydia.Downloads.Client.Debrid.Providers.AllDebridTest do
  @moduledoc """
  Bypass-only tests for the AllDebrid provider — no real-account
  validation. See provider module docs.
  """
  use ExUnit.Case, async: false

  alias Mydia.Downloads.Client.Debrid.Providers.AllDebrid
  alias Mydia.Downloads.Client.Debrid.ProviderJob
  alias Mydia.Downloads.Client.Error

  setup do
    bypass = Bypass.open()
    base = "http://127.0.0.1:#{bypass.port}"

    prior = Application.get_env(:mydia, :all_debrid_base_url)
    Application.put_env(:mydia, :all_debrid_base_url, base)
    on_exit(fn -> Application.put_env(:mydia, :all_debrid_base_url, prior) end)

    {:ok, bypass: bypass, config: %{api_key: "ad-test-token", type: :debrid}}
  end

  defp success_envelope(data) do
    Jason.encode!(%{"status" => "success", "data" => data})
  end

  defp error_envelope(code, message \\ "err") do
    Jason.encode!(%{"status" => "error", "error" => %{"code" => code, "message" => message}})
  end

  # A real `.torrent` is bencoded with a `pieces` field of raw SHA-1 bytes,
  # so the multipart body must carry arbitrary (invalid-UTF8) bytes through
  # untouched. Using an ASCII-only fixture would not catch a body that gets
  # mangled by an encoding step on the way out.
  defp torrent_fixture do
    "d8:announce13:https://tr/abc4:infod6:lengthi1e4:name7:mayabee6:pieces20:" <>
      <<0xFF, 0xFE, 0x00, 0x01, 0x80, 0x7F, 0xC3, 0x28, 0xA0, 0xA1, 0xF0, 0x9F, 0x92, 0xA9, 0x00,
        0xDE, 0xAD, 0xBE, 0xEF, 0x00>> <> "ee"
  end

  describe "validate_credentials/1" do
    test "premium user returns ok", %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "GET", "/v4/user", fn conn ->
        future = System.os_time(:second) + 86_400

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          success_envelope(%{"user" => %{"isPremium" => true, "premiumUntil" => future}})
        )
      end)

      assert {:ok, _} = AllDebrid.validate_credentials(config)
    end

    test "AUTH_BAD_APIKEY returns :authentication_failed", %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "GET", "/v4/user", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, error_envelope("AUTH_BAD_APIKEY"))
      end)

      assert {:error, %Error{type: :authentication_failed}} =
               AllDebrid.validate_credentials(config)
    end

    test "MUST_BE_PREMIUM maps to authentication_failed with subscription_required",
         %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "GET", "/v4/user", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, error_envelope("MUST_BE_PREMIUM"))
      end)

      assert {:error,
              %Error{type: :authentication_failed, details: %{reason: :subscription_required}}} =
               AllDebrid.validate_credentials(config)
    end
  end

  describe "submit_torrent/2" do
    test "magnet returns the id from data.magnets[0]", %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "POST", "/v4/magnet/upload", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          success_envelope(%{"magnets" => [%{"id" => 42, "ready" => false}]})
        )
      end)

      assert {:ok, "42"} = AllDebrid.submit_torrent(config, {:magnet, "magnet:?xt=abc"})
    end

    test "cached release (ready: true) still returns the id", %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "POST", "/v4/magnet/upload", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, success_envelope(%{"magnets" => [%{"id" => 99, "ready" => true}]}))
      end)

      assert {:ok, "99"} = AllDebrid.submit_torrent(config, {:magnet, "magnet:?xt=cached"})
    end

    test "MAGNET_TOO_MANY_ACTIVE returns slot_limit", %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "POST", "/v4/magnet/upload", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, error_envelope("MAGNET_TOO_MANY_ACTIVE"))
      end)

      assert {:error, %Error{type: :api_error, details: %{reason: :slot_limit}}} =
               AllDebrid.submit_torrent(config, {:magnet, "magnet:?xt=full"})
    end

    test "torrent file upload uses Req-compatible multipart body", %{
      bypass: bypass,
      config: config
    } do
      test_pid = self()

      Bypass.expect(bypass, "POST", "/v4/magnet/upload/file", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 1_000_000)
        send(test_pid, {:upload, Plug.Conn.get_req_header(conn, "content-type"), body})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, success_envelope(%{"files" => [%{"id" => 77}]}))
      end)

      assert {:ok, "77"} = AllDebrid.submit_torrent(config, {:file, torrent_fixture()})

      assert_received {:upload, [content_type | _], body}
      assert content_type =~ "multipart/form-data"
      assert body =~ ~s(name="files[]")
      assert body =~ ~s(filename="release.torrent")
      assert body =~ "application/x-bittorrent"
      assert body =~ torrent_fixture()
    end
  end

  describe "get_job/2 status code mapping" do
    for {code, expected_state} <- [
          {0, :queued},
          {1, :downloading},
          {2, :finalizing},
          {3, :finalizing},
          {4, :ready},
          {5, :error},
          {7, :error},
          {10, :error},
          {11, :error},
          {12, :error}
        ] do
      test "statusCode #{code} maps to #{inspect(expected_state)}", %{
        bypass: bypass,
        config: config
      } do
        Bypass.expect(bypass, "POST", "/v4.1/magnet/status", fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            200,
            success_envelope(%{
              "magnets" => %{"id" => 1, "statusCode" => unquote(code), "size" => 100}
            })
          )
        end)

        assert {:ok, %ProviderJob{state: unquote(expected_state)}} =
                 AllDebrid.get_job(config, "1")
      end
    end
  end

  describe "list_jobs/2" do
    test "empty input returns empty map", %{config: config} do
      assert {:ok, %{}} = AllDebrid.list_jobs(config, [])
    end

    test "filters to requested IDs", %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "POST", "/v4.1/magnet/status", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          success_envelope(%{
            "magnets" => [
              %{"id" => 1, "statusCode" => 4, "size" => 100},
              %{"id" => 2, "statusCode" => 1, "size" => 50},
              %{"id" => 99, "statusCode" => 5, "size" => 0}
            ]
          })
        )
      end)

      assert {:ok, jobs} = AllDebrid.list_jobs(config, ["1", "2"])
      assert map_size(jobs) == 2
      assert %ProviderJob{state: :ready} = jobs["1"]
      assert %ProviderJob{state: :downloading} = jobs["2"]
      refute Map.has_key?(jobs, "99")
    end
  end

  describe "get_download_urls/2" do
    test "flattens a nested folder tree's `l` URLs in order", %{bypass: bypass, config: config} do
      tree = [
        %{"l" => "https://link/1"},
        %{
          "e" => [
            %{"l" => "https://link/2"},
            %{"e" => [%{"l" => "https://link/3"}]}
          ]
        }
      ]

      Bypass.expect(bypass, "POST", "/v4/magnet/files", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, success_envelope(%{"magnets" => [%{"files" => tree}]}))
      end)

      job = %ProviderJob{provider_id: "1", state: :ready}
      assert {:ok, urls} = AllDebrid.get_download_urls(config, job)
      assert urls == ["https://link/1", "https://link/2", "https://link/3"]
    end
  end

  describe "delete_job/2" do
    test "200 + success envelope returns :ok", %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "POST", "/v4/magnet/delete", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, success_envelope(%{}))
      end)

      assert :ok = AllDebrid.delete_job(config, "1")
    end
  end

  describe "rate_limit_budget/0" do
    test "returns {600, 60}", do: assert(AllDebrid.rate_limit_budget() == {600, 60})
  end
end
