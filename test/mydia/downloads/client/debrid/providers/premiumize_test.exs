defmodule Mydia.Downloads.Client.Debrid.Providers.PremiumizeTest do
  @moduledoc """
  Bypass-only tests for the Premiumize provider — no real-account validation.
  """
  use ExUnit.Case, async: false

  alias Mydia.Downloads.Client.Debrid.Providers.Premiumize
  alias Mydia.Downloads.Client.Debrid.ProviderJob
  alias Mydia.Downloads.Client.Error

  setup do
    bypass = Bypass.open()
    base = "http://127.0.0.1:#{bypass.port}"

    prior = Application.get_env(:mydia, :premiumize_base_url)
    Application.put_env(:mydia, :premiumize_base_url, base)
    on_exit(fn -> Application.put_env(:mydia, :premiumize_base_url, prior) end)

    {:ok, bypass: bypass, config: %{api_key: "pm-token", type: :debrid}}
  end

  defp success(extra), do: Jason.encode!(Map.merge(%{"status" => "success"}, extra))
  defp error_body(msg), do: Jason.encode!(%{"status" => "error", "message" => msg})

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
    test "active subscription returns ok", %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "GET", "/account/info", fn conn ->
        future = System.os_time(:second) + 86_400

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, success(%{"premium_until" => future}))
      end)

      assert {:ok, _} = Premiumize.validate_credentials(config)
    end
  end

  describe "submit_torrent/2" do
    test "magnet returns the transfer id", %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "POST", "/transfer/create", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, success(%{"id" => "transfer_abc"}))
      end)

      assert {:ok, "transfer_abc"} =
               Premiumize.submit_torrent(config, {:magnet, "magnet:?xt=x"})
    end

    test "torrent file upload uses Req-compatible multipart body", %{
      bypass: bypass,
      config: config
    } do
      test_pid = self()

      Bypass.expect(bypass, "POST", "/transfer/create", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 1_000_000)
        send(test_pid, {:upload, Plug.Conn.get_req_header(conn, "content-type"), body})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, success(%{"id" => "transfer_file"}))
      end)

      assert {:ok, "transfer_file"} =
               Premiumize.submit_torrent(config, {:file, torrent_fixture()})

      assert_received {:upload, [content_type | _], body}
      assert content_type =~ "multipart/form-data"
      assert body =~ ~s(name="src")
      assert body =~ ~s(filename="release.torrent")
      assert body =~ "application/x-bittorrent"
      assert body =~ torrent_fixture()
    end
  end

  describe "get_job/2" do
    test "finished status maps to :ready", %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "GET", "/transfer/list", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          success(%{
            "transfers" => [
              %{
                "id" => "t1",
                "status" => "finished",
                "name" => "Release",
                "size" => 100,
                "progress" => 1.0
              }
            ]
          })
        )
      end)

      assert {:ok, %ProviderJob{state: :ready, name: "Release"}} =
               Premiumize.get_job(config, "t1")
    end

    test "id not in transfer list returns :not_found", %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "GET", "/transfer/list", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, success(%{"transfers" => []}))
      end)

      assert {:error, %Error{type: :not_found}} = Premiumize.get_job(config, "missing")
    end
  end

  describe "list_jobs/2" do
    test "filters to requested ids", %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "GET", "/transfer/list", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          success(%{
            "transfers" => [
              %{"id" => "1", "status" => "running", "progress" => 0.5, "size" => 100},
              %{"id" => "2", "status" => "finished", "progress" => 1.0, "size" => 50},
              %{"id" => "99", "status" => "error", "size" => 0, "progress" => 0}
            ]
          })
        )
      end)

      assert {:ok, jobs} = Premiumize.list_jobs(config, ["1", "2"])
      assert map_size(jobs) == 2
      refute Map.has_key?(jobs, "99")
    end
  end

  describe "get_download_urls/2" do
    test "file transfer: returns single link", %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "GET", "/item/details", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, success(%{"link" => "https://pm.example/file.bin"}))
      end)

      job = %ProviderJob{provider_id: "1", state: :ready, raw_status: %{"file_id" => "F1"}}

      assert {:ok, ["https://pm.example/file.bin"]} =
               Premiumize.get_download_urls(config, job)
    end

    test "folder transfer: flattens nested folder/list responses", %{
      bypass: bypass,
      config: config
    } do
      :persistent_term.put({__MODULE__, :calls}, 0)

      Bypass.expect(bypass, "GET", "/folder/list", fn conn ->
        count = :persistent_term.get({__MODULE__, :calls}, 0) + 1
        :persistent_term.put({__MODULE__, :calls}, count)

        body =
          case count do
            1 ->
              success(%{
                "content" => [
                  %{"type" => "file", "link" => "https://pm.example/a.bin"},
                  %{"type" => "folder", "id" => "F-inner"}
                ]
              })

            _ ->
              success(%{
                "content" => [
                  %{"type" => "file", "link" => "https://pm.example/b.bin"}
                ]
              })
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, body)
      end)

      job = %ProviderJob{provider_id: "1", state: :ready, raw_status: %{"folder_id" => "F-outer"}}
      assert {:ok, urls} = Premiumize.get_download_urls(config, job)
      assert "https://pm.example/a.bin" in urls
      assert "https://pm.example/b.bin" in urls
    end
  end

  describe "envelope errors" do
    test "rate_limit_reached maps to :rate_limited", %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "POST", "/transfer/create", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, error_body("rate_limit_reached"))
      end)

      assert {:error, %Error{type: :api_error, details: %{reason: :rate_limited}}} =
               Premiumize.submit_torrent(config, {:magnet, "magnet:?xt=throttle"})
    end
  end

  describe "rate_limit_budget/0" do
    test "returns {30, 60}", do: assert(Premiumize.rate_limit_budget() == {30, 60})
  end
end
