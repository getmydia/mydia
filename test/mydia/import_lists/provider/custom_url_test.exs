defmodule Mydia.ImportLists.Provider.CustomURLTest do
  # Mutates the global :mydia, :import_lists_allow_private_destinations app env,
  # so this suite runs sequentially.
  use ExUnit.Case, async: false

  alias Mydia.ImportLists.Provider.CustomURL

  @config_key :import_lists_allow_private_destinations

  defp import_list(url) do
    %{type: "custom_url", config: %{"list_url" => url}, media_type: "movie"}
  end

  # Bypass only ever binds to loopback, which the guard blocks by default, so
  # every Bypass-backed test needs the escape hatch just to reach the server at
  # all. Restored via on_exit so later tests see the secure default again.
  defp allow_private_destinations! do
    previous = Application.get_env(:mydia, @config_key)
    Application.put_env(:mydia, @config_key, true)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:mydia, @config_key)
      else
        Application.put_env(:mydia, @config_key, previous)
      end
    end)
  end

  describe "fetch_items/1 JSON shapes (guard relaxed via Bypass)" do
    setup do
      allow_private_destinations!()
      bypass = Bypass.open()
      %{bypass: bypass}
    end

    test "parses a bare array of items", %{bypass: bypass} do
      body =
        Jason.encode!([
          %{"tmdb_id" => 111, "title" => "The Wandering Reactor", "year" => 2024},
          %{"tmdb_id" => 222, "title" => "Silent Orchard"}
        ])

      Bypass.expect_once(bypass, "GET", "/list.json", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, body)
      end)

      list = import_list("http://localhost:#{bypass.port}/list.json")

      assert {:ok, items} = CustomURL.fetch_items(list)
      assert length(items) == 2
      assert Enum.any?(items, &(&1.tmdb_id == 111 and &1.title == "The Wandering Reactor"))
      assert Enum.any?(items, &(&1.tmdb_id == 222))
    end

    test "parses an object with an items key", %{bypass: bypass} do
      body = Jason.encode!(%{"items" => [%{"tmdb_id" => 333, "title" => "Glass Meridian"}]})

      Bypass.expect_once(bypass, "GET", "/list.json", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, body)
      end)

      list = import_list("http://localhost:#{bypass.port}/list.json")

      assert {:ok, [item]} = CustomURL.fetch_items(list)
      assert item.tmdb_id == 333
      assert item.title == "Glass Meridian"
    end

    test "parses an object with a results key", %{bypass: bypass} do
      body = Jason.encode!(%{"results" => [%{"tmdb_id" => 444, "title" => "Copper Latitude"}]})

      Bypass.expect_once(bypass, "GET", "/list.json", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, body)
      end)

      list = import_list("http://localhost:#{bypass.port}/list.json")

      assert {:ok, [item]} = CustomURL.fetch_items(list)
      assert item.tmdb_id == 444
    end

    test "parses Radarr/Sonarr-style tmdbId and skips items without any tmdb id", %{
      bypass: bypass
    } do
      body =
        Jason.encode!([
          %{"tmdbId" => 555, "title" => "Basalt Overture"},
          %{"title" => "No Identifier Here"}
        ])

      Bypass.expect_once(bypass, "GET", "/list.json", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, body)
      end)

      list = import_list("http://localhost:#{bypass.port}/list.json")

      assert {:ok, items} = CustomURL.fetch_items(list)
      assert [%{tmdb_id: 555, title: "Basalt Overture"}] = items
    end
  end

  describe "fetch_items/1 redirect revalidation (guard relaxed via Bypass)" do
    setup do
      allow_private_destinations!()
      bypass = Bypass.open()
      %{bypass: bypass}
    end

    test "rejects a redirect into a blocked destination instead of following it", %{
      bypass: bypass
    } do
      # The origin (Bypass, on loopback) is only reachable because the guard is
      # relaxed for this test. The scheme allowlist is *not* affected by that
      # switch, so redirecting to a disallowed scheme proves each hop is
      # independently revalidated rather than the guard only checking the
      # original URL once.
      Bypass.expect_once(bypass, "GET", "/list.json", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "ftp://blocked.invalid/data")
        |> Plug.Conn.resp(302, "")
      end)

      list = import_list("http://localhost:#{bypass.port}/list.json")

      assert {:error, reason} = CustomURL.fetch_items(list)
      assert reason =~ "scheme"
    end
  end

  describe "validate_url/1 SSRF guard (direct calls, default secure config)" do
    test "rejects non-http(s) schemes" do
      assert {:error, reason} = CustomURL.validate_url("file:///etc/passwd")
      assert reason =~ "scheme"

      assert {:error, _reason} = CustomURL.validate_url("ftp://example.com/list.json")
    end

    test "rejects a literal loopback address" do
      assert {:error, reason} = CustomURL.validate_url("http://127.0.0.1/list.json")
      assert reason =~ "127.0.0.1"

      assert {:error, _reason} = CustomURL.validate_url("http://[::1]/list.json")
    end

    test "rejects literal RFC1918 private addresses" do
      assert {:error, _reason} = CustomURL.validate_url("http://10.0.0.5/list.json")
      assert {:error, _reason} = CustomURL.validate_url("http://172.16.0.5/list.json")
      assert {:error, _reason} = CustomURL.validate_url("http://192.168.1.5/list.json")
    end

    test "rejects link-local addresses, including the cloud metadata IP" do
      assert {:error, reason} = CustomURL.validate_url("http://169.254.169.254/latest/meta-data/")
      assert reason =~ "169.254.169.254"

      assert {:error, _reason} = CustomURL.validate_url("http://[fe80::1]/list.json")
    end

    test "rejects unique-local IPv6, unspecified, and broadcast addresses" do
      assert {:error, _reason} = CustomURL.validate_url("http://[fc00::1]/list.json")
      assert {:error, _reason} = CustomURL.validate_url("http://0.0.0.0/list.json")
      assert {:error, _reason} = CustomURL.validate_url("http://255.255.255.255/list.json")
    end

    test "rejects an IPv4-mapped IPv6 loopback address" do
      assert {:error, reason} = CustomURL.validate_url("http://[::ffff:127.0.0.1]/list.json")
      assert reason =~ "127.0.0.1"
    end

    test "rejects a hostname that resolves to a blocked address" do
      assert {:error, reason} = CustomURL.validate_url("http://localhost/list.json")
      assert reason =~ "localhost"
    end
  end

  describe "validate_url/1 with the config switch enabled" do
    setup do
      allow_private_destinations!()
      :ok
    end

    test "allows private destinations once explicitly enabled" do
      assert :ok = CustomURL.validate_url("http://127.0.0.1/list.json")
      assert :ok = CustomURL.validate_url("http://169.254.169.254/latest/meta-data/")
    end

    test "still enforces the scheme allowlist" do
      assert {:error, reason} = CustomURL.validate_url("file:///etc/passwd")
      assert reason =~ "scheme"
    end
  end
end
