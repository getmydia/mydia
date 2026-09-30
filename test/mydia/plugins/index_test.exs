defmodule Mydia.Plugins.IndexTest do
  # DataCase: catalog/package fetches route through the gate, which emits an
  # audit event (Events.create_event_async runs synchronously under the sandbox).
  use Mydia.DataCase, async: true

  alias Mydia.Plugins.Error
  alias Mydia.Plugins.Index
  alias Mydia.Plugins.Index.Entry

  # Build a real (tiny) wasm module so the integrity hash is computed over actual
  # bytes rather than a fixture that can drift.
  defp wasm_fixture do
    {:ok, bytes} = Wasmex.Wat.to_wasm("(module)")
    bytes
  end

  defp sha256_hex(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp manifest_json do
    %{
      "slug" => "webhook-notifier",
      "name" => "Webhook Notifier",
      "version" => "1.0.0",
      "description" => "Posts events to a webhook",
      "author" => "Mydia",
      "capabilities" => %{
        "events:subscribe" => ["media_item.added"],
        "net:http" => ["discord.com"]
      }
    }
  end

  defp catalog_json(package_url, integrity) do
    Jason.encode!(%{
      "version" => 1,
      "plugins" => [
        %{
          "package_url" => package_url,
          "integrity" => integrity,
          "manifest" => manifest_json()
        }
      ]
    })
  end

  defp loopback, do: fn _ -> {:ok, [{127, 0, 0, 1}]} end

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass}
  end

  describe "fetch_catalog/2" do
    test "fetches and parses a catalog into entries", %{bypass: bypass} do
      wasm = wasm_fixture()
      pkg_url = "http://allowed.test:#{bypass.port}/pkg.wasm"

      Bypass.expect_once(bypass, "GET", "/index.json", fn conn ->
        Plug.Conn.resp(conn, 200, catalog_json(pkg_url, "sha256:#{sha256_hex(wasm)}"))
      end)

      assert {:ok, [%Entry{} = entry]} =
               Index.fetch_catalog("http://allowed.test:#{bypass.port}/index.json",
                 allow_private: true,
                 resolver: loopback()
               )

      assert entry.slug == "webhook-notifier"
      assert entry.version == "1.0.0"
      assert entry.package_url == pkg_url
      assert entry.manifest.capabilities["net:http"] == ["discord.com"]
    end

    test "R13: a custom source URL is fetched and parsed", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/custom.json", fn conn ->
        Plug.Conn.resp(conn, 200, catalog_json("http://allowed.test/p.wasm", "sha256:ab"))
      end)

      assert {:ok, [%Entry{slug: "webhook-notifier"}]} =
               Index.fetch_catalog("http://allowed.test:#{bypass.port}/custom.json",
                 allow_private: true,
                 resolver: loopback()
               )
    end

    test "refuses a source resolving to a private IP (via the gate)" do
      assert {:error, %Error{type: :blocked}} =
               Index.fetch_catalog("https://source.test/index.json",
                 resolver: fn _ -> {:ok, [{169, 254, 169, 254}]} end
               )
    end

    test "rejects a non-https source URL at fetch time" do
      assert {:error, %Error{type: :invalid_config, message: msg}} =
               Index.fetch_catalog("http://insecure.test/index.json")

      assert msg =~ "https"
    end

    test "returns a clear error for malformed catalog JSON", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/index.json", fn conn ->
        Plug.Conn.resp(conn, 200, "{not json")
      end)

      assert {:error, %Error{type: :invalid_config}} =
               Index.fetch_catalog("http://allowed.test:#{bypass.port}/index.json",
                 allow_private: true,
                 resolver: loopback()
               )
    end

    test "drops a listing whose embedded manifest is invalid", %{bypass: bypass} do
      bad =
        Jason.encode!(%{
          "version" => 1,
          "plugins" => [
            %{"package_url" => "http://x/p.wasm", "integrity" => "sha256:ab", "manifest" => %{}}
          ]
        })

      Bypass.expect_once(bypass, "GET", "/index.json", fn conn ->
        Plug.Conn.resp(conn, 200, bad)
      end)

      assert {:ok, []} =
               Index.fetch_catalog("http://allowed.test:#{bypass.port}/index.json",
                 allow_private: true,
                 resolver: loopback()
               )
    end
  end

  describe "fetch_package/2 (integrity)" do
    test "returns the package when the hash matches", %{bypass: bypass} do
      wasm = wasm_fixture()
      hash = sha256_hex(wasm)

      Bypass.expect_once(bypass, "GET", "/pkg.wasm", fn conn ->
        Plug.Conn.resp(conn, 200, wasm)
      end)

      entry = %Entry{
        slug: "p",
        name: "P",
        version: "1.0.0",
        package_url: "http://allowed.test:#{bypass.port}/pkg.wasm",
        integrity: "sha256:#{hash}",
        manifest: %Mydia.Plugins.Manifest{slug: "p", name: "P", version: "1.0.0"}
      }

      assert {:ok, %{wasm: ^wasm, hash: ^hash}} =
               Index.fetch_package(entry, allow_private: true, resolver: loopback())
    end

    test "AE4: rejects a package whose hash does not match the declared value", %{bypass: bypass} do
      wasm = wasm_fixture()

      Bypass.expect_once(bypass, "GET", "/pkg.wasm", fn conn ->
        Plug.Conn.resp(conn, 200, wasm)
      end)

      entry = %Entry{
        slug: "p",
        name: "P",
        version: "1.0.0",
        package_url: "http://allowed.test:#{bypass.port}/pkg.wasm",
        integrity: "sha256:deadbeef",
        manifest: %Mydia.Plugins.Manifest{slug: "p", name: "P", version: "1.0.0"}
      }

      assert {:error, %Error{type: :integrity_mismatch}} =
               Index.fetch_package(entry, allow_private: true, resolver: loopback())
    end
  end

  describe "verify_integrity/2" do
    test "accepts bare hex and sha256-prefixed, case-insensitively" do
      bytes = "hello"
      hash = sha256_hex(bytes)

      assert {:ok, _} = Index.verify_integrity(bytes, hash)
      assert {:ok, _} = Index.verify_integrity(bytes, "sha256:#{String.upcase(hash)}")
      assert {:error, %Error{type: :integrity_mismatch}} = Index.verify_integrity(bytes, "00")
    end
  end

  describe "sources/0" do
    test "includes the official index by default" do
      assert Index.official_index_url() =~ "https://"
      assert Index.official_index_url() in Index.sources()
    end
  end

  describe "browse/2" do
    alias Mydia.Plugins.Index.BrowseResult

    defp browse_opts(bypass, paths) do
      [
        sources: Enum.map(paths, &"http://allowed.test:#{bypass.port}#{&1}"),
        allow_private: true,
        resolver: loopback()
      ]
    end

    defp serve(bypass, path, body) do
      Bypass.expect_once(bypass, "GET", path, fn conn -> Plug.Conn.resp(conn, 200, body) end)
    end

    test "lists entries that are not installed", %{bypass: bypass} do
      serve(bypass, "/index.json", catalog_json("http://allowed.test/p.wasm", "sha256:ab"))

      assert %BrowseResult{status: :available, error: nil, source_count: 1, catalog: [entry]} =
               Index.browse([], browse_opts(bypass, ["/index.json"]))

      assert entry.slug == "webhook-notifier"
    end

    test "reports :all_installed when every listed entry is installed", %{bypass: bypass} do
      serve(bypass, "/index.json", catalog_json("http://allowed.test/p.wasm", "sha256:ab"))

      assert %BrowseResult{status: :all_installed, catalog: [], error: nil} =
               Index.browse(["webhook-notifier"], browse_opts(bypass, ["/index.json"]))
    end

    test "reports :empty when the source lists nothing", %{bypass: bypass} do
      serve(bypass, "/index.json", Jason.encode!(%{"version" => 1, "plugins" => []}))

      assert %BrowseResult{status: :empty, catalog: [], error: nil, source_count: 1} =
               Index.browse([], browse_opts(bypass, ["/index.json"]))
    end

    test "keeps entries from a working source when another fails", %{bypass: bypass} do
      serve(bypass, "/index.json", catalog_json("http://allowed.test/p.wasm", "sha256:ab"))

      Bypass.expect_once(bypass, "GET", "/missing.json", fn conn ->
        Plug.Conn.resp(conn, 404, "")
      end)

      assert %BrowseResult{status: :available, catalog: [_], source_count: 2, error: error} =
               Index.browse([], browse_opts(bypass, ["/index.json", "/missing.json"]))

      assert error =~ "HTTP 404"
    end

    test "reports :empty with no sources configured" do
      assert %BrowseResult{status: :empty, catalog: [], error: nil, source_count: 0} =
               Index.browse([], sources: [])
    end
  end
end
