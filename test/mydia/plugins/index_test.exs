defmodule Mydia.Plugins.IndexTest do
  # DataCase: catalog/package fetches route through the gate, which emits an
  # audit event (Events.create_event_async runs synchronously under the sandbox).
  use Mydia.DataCase, async: true

  import Mydia.MinisignFixtures

  alias Mydia.Plugins.Error
  alias Mydia.Plugins.Index
  alias Mydia.Plugins.Index.Entry
  alias Mydia.Plugins.Index.{Signature, Source}
  alias Mydia.Settings.PluginConfig

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

  defp catalog(package_url, integrity, extra \\ %{}) do
    Map.merge(
      %{
        "version" => 2,
        "name" => "Fixture Plugins",
        "plugins" => [
          %{"package_url" => package_url, "integrity" => integrity, "manifest" => manifest_json()}
        ]
      },
      extra
    )
  end

  defp url(bypass, path), do: "http://allowed.test:#{bypass.port}#{path}"

  defp source(bypass, path, keys, id \\ nil) do
    {:ok, key} = Signature.parse_public_key(keys.public)
    %Source{id: id, url: url(bypass, path), name: "Fixture Plugins", public_key: key}
  end

  # Serves `path` and its detached signature, signed by `keys`.
  defp serve_signed(bypass, path, map, keys, opts \\ []) do
    body = Jason.encode!(Map.put_new(map, "public_key", keys.public))
    signer = Keyword.get(opts, :signer, keys)
    Bypass.stub(bypass, "GET", path, fn conn -> Plug.Conn.resp(conn, 200, body) end)

    Bypass.stub(bypass, "GET", path <> ".minisig", fn conn ->
      Plug.Conn.resp(conn, 200, sign(body, signer))
    end)
  end

  defp gate_opts, do: [allow_private: true, resolver: loopback()]

  describe "fetch_catalog/2" do
    test "fetches, verifies and parses a signed catalog", %{bypass: bypass} do
      keys = keypair()
      wasm = wasm_fixture()
      pkg = url(bypass, "/pkg.wasm")
      serve_signed(bypass, "/index.json", catalog(pkg, "sha256:#{sha256_hex(wasm)}"), keys)
      id = Ecto.UUID.generate()

      assert {:ok, [%Entry{} = entry]} =
               Index.fetch_catalog(source(bypass, "/index.json", keys, id), gate_opts())

      assert entry.slug == "webhook-notifier"
      assert entry.package_url == pkg
      assert entry.source_id == id
      assert entry.source_name == "Fixture Plugins"
      assert entry.manifest.capabilities["net:http"] == ["discord.com"]
    end

    test "refuses a catalog with no signature", %{bypass: bypass} do
      keys = keypair()

      Bypass.stub(bypass, "GET", "/index.json", fn conn ->
        Plug.Conn.resp(conn, 200, Jason.encode!(catalog("https://x.test/p.wasm", "sha256:ab")))
      end)

      Bypass.stub(bypass, "GET", "/index.json.minisig", fn conn ->
        Plug.Conn.resp(conn, 404, "")
      end)

      assert {:error, %Error{}} =
               Index.fetch_catalog(source(bypass, "/index.json", keys), gate_opts())
    end

    test "refuses a catalog signed by another key", %{bypass: bypass} do
      keys = keypair()

      serve_signed(bypass, "/index.json", catalog("https://x.test/p.wasm", "sha256:ab"), keys,
        signer: keypair()
      )

      assert {:error, %Error{type: :signature_invalid}} =
               Index.fetch_catalog(source(bypass, "/index.json", keys), gate_opts())
    end

    test "reports a rotated key as key_changed", %{bypass: bypass} do
      pinned = keypair()
      rotated = keypair()
      serve_signed(bypass, "/index.json", catalog("https://x.test/p.wasm", "sha256:ab"), rotated)

      assert {:error, %Error{type: :key_changed}} =
               Index.fetch_catalog(source(bypass, "/index.json", pinned), gate_opts())
    end

    test "records success and failure on the source row", %{bypass: bypass} do
      keys = keypair()

      {:ok, row} =
        Mydia.Plugins.Sources.add_source(%{
          url: "https://allowed.test/#{bypass.port}/index.json",
          public_key: keys.public
        })

      serve_signed(bypass, "/index.json", catalog("https://x.test/p.wasm", "sha256:ab"), keys)
      {:ok, _} = Index.fetch_catalog(source(bypass, "/index.json", keys, row.id), gate_opts())
      assert %{plugin_count: 1, last_error: nil} = Repo.reload!(row)

      {:error, _} =
        Index.fetch_catalog(source(bypass, "/index.json", keypair(), row.id), gate_opts())

      assert Repo.reload!(row).last_error =~ "key"
    end

    test "refuses a source resolving to a private IP (via the gate)" do
      {:ok, key} = Signature.parse_public_key(keypair().public)
      source = %Source{url: "https://source.test/index.json", name: "x", public_key: key}

      assert {:error, %Error{type: :blocked}} =
               Index.fetch_catalog(source, resolver: fn _ -> {:ok, [{169, 254, 169, 254}]} end)
    end

    test "rejects a non-https source URL at fetch time" do
      {:ok, key} = Signature.parse_public_key(keypair().public)
      source = %Source{url: "http://insecure.test/index.json", name: "x", public_key: key}
      assert {:error, %Error{type: :invalid_config}} = Index.fetch_catalog(source)
    end

    test "returns a clear error for a signed body that is not JSON", %{bypass: bypass} do
      keys = keypair()

      Bypass.stub(bypass, "GET", "/index.json", fn conn ->
        Plug.Conn.resp(conn, 200, "{not json")
      end)

      Bypass.stub(bypass, "GET", "/index.json.minisig", fn conn ->
        Plug.Conn.resp(conn, 200, sign("{not json", keys))
      end)

      assert {:error, %Error{type: :invalid_config}} =
               Index.fetch_catalog(source(bypass, "/index.json", keys), gate_opts())
    end

    test "drops a listing whose embedded manifest is invalid", %{bypass: bypass} do
      keys = keypair()

      bad = %{
        "package_url" => "https://x.test/p.wasm",
        "integrity" => "sha256:ab",
        "manifest" => %{}
      }

      serve_signed(bypass, "/index.json", %{"version" => 2, "plugins" => [bad]}, keys)

      assert {:ok, []} = Index.fetch_catalog(source(bypass, "/index.json", keys), gate_opts())
    end
  end

  describe "preview_source/2" do
    test "verifies against the embedded key and reports what would be pinned", %{bypass: bypass} do
      keys = keypair()
      serve_signed(bypass, "/index.json", catalog("https://x.test/p.wasm", "sha256:ab"), keys)

      assert {:ok, preview} = Index.preview_source(url(bypass, "/index.json"), gate_opts())
      assert preview.name == "Fixture Plugins"
      assert preview.public_key == keys.public
      assert preview.fingerprint =~ ~r/^[0-9A-F]{16}$/
      assert preview.plugin_count == 1
    end

    test "refuses a catalog that embeds no key", %{bypass: bypass} do
      Bypass.stub(bypass, "GET", "/index.json", fn conn ->
        Plug.Conn.resp(conn, 200, Jason.encode!(%{"version" => 1, "plugins" => []}))
      end)

      assert {:error, %Error{type: :signature_invalid}} =
               Index.preview_source(url(bypass, "/index.json"), gate_opts())
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
    test "starts with the official index and its compiled-in key" do
      assert [%Source{official?: true, id: nil, url: url} | _] = Index.sources()
      assert url == Index.official_index_url()
    end

    test "appends enabled source rows" do
      {:ok, row} =
        Mydia.Plugins.Sources.add_source(%{
          url: "https://a.test/index.json",
          public_key: keypair().public
        })

      assert Enum.any?(Index.sources(), &(&1.id == row.id))
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

    test "lists every entry, installed or not", %{bypass: bypass} do
      serve(bypass, "/index.json", catalog_json("http://allowed.test/p.wasm", "sha256:ab"))

      installed = [
        %PluginConfig{
          slug: "webhook-notifier",
          version: "1.0.0",
          source_url: "https://cdn.test/p-1.0.0.wasm"
        }
      ]

      assert %BrowseResult{status: :available, error: nil, source_count: 1, catalog: [item]} =
               Index.browse(installed, browse_opts(bypass, ["/index.json"]))

      assert item.entry.slug == "webhook-notifier"
    end

    test "classifies each entry against what is installed", %{bypass: bypass} do
      Bypass.stub(bypass, "GET", "/index.json", fn conn ->
        Plug.Conn.resp(conn, 200, catalog_json("http://allowed.test/p.wasm", "sha256:ab"))
      end)

      # The catalog lists webhook-notifier at 1.0.0.
      cases = [
        {nil, :not_installed, nil},
        {{"bundled", "0.9.0"}, :bundled, "0.9.0"},
        {{"https://cdn.test/p-1.0.0.wasm", "1.0.0"}, :installed, "1.0.0"},
        {{"https://cdn.test/p-0.9.0.wasm", "0.9.0"}, :update, "0.9.0"},
        {{"https://cdn.test/p-2.0.0.wasm", "2.0.0"}, :replace, "2.0.0"},
        {{"file:///home/op/p.wasm", "1.0.0"}, :replace, "1.0.0"}
      ]

      for {installed, state, installed_version} <- cases do
        configs =
          case installed do
            nil -> []
            {url, v} -> [%PluginConfig{slug: "webhook-notifier", version: v, source_url: url}]
          end

        assert %BrowseResult{catalog: [item]} =
                 Index.browse(configs, browse_opts(bypass, ["/index.json"]))

        assert {item.state, item.installed_version} == {state, installed_version},
               "installed as #{inspect(installed)}"
      end
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

  describe "version_newer?/2" do
    test "compares semver, treats nil as oldest, and falls back to string order" do
      refute Index.version_newer?("1.2.0", "1.10.0")
      assert Index.version_newer?("1.10.0", "1.2.0")
      refute Index.version_newer?("1.0.0", "1.0.0")
      assert Index.version_newer?("1.0.0", nil)
      assert Index.version_newer?("b", "a")
    end
  end
end
