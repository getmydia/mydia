# scripts/build_plugin_index.exs
#
# Builds the official plugin index for the plugins under plugins-extra/.
#
#   elixir scripts/build_plugin_index.exs --wasm-dir build/wasm --out build/site
#
# Options: --base-url, --crates-dir, --name (catalog name, default "Mydia") and
# --public-key (minisign public key file, default priv/plugin_index/official.pub).
# The bare base64 key is embedded in the catalog. The script does not sign:
# the publish workflow signs the output as index.json.minisig.
#
# For every <crates-dir>/<crate>/manifest.json it expects a built
# <wasm-dir>/<crate>.wasm, copies it to <out>/packages/<slug>/<version>.wasm and
# lists it in <out>/index.json in the catalog format Mydia.Plugins.Index reads.
#
# Dependency-free on purpose (Elixir's built-in JSON), so the publish workflow
# does not have to compile the whole application. Manifest validation against
# Mydia.Plugins.Manifest happens in the test suite instead.
defmodule BuildPluginIndex do
  @default_base_url "https://plugins.mydia.dev"

  def main(argv) do
    {opts, _rest, invalid} =
      OptionParser.parse(argv,
        strict: [
          wasm_dir: :string,
          out: :string,
          base_url: :string,
          crates_dir: :string,
          public_key: :string,
          name: :string
        ]
      )

    if invalid != [], do: fail("unknown options: #{inspect(invalid)}")

    wasm_dir = opts[:wasm_dir] || fail("--wasm-dir is required")
    out = opts[:out] || fail("--out is required")
    base_url = String.trim_trailing(opts[:base_url] || @default_base_url, "/")
    crates_dir = opts[:crates_dir] || "plugins-extra"

    public_key = read_public_key(opts[:public_key] || "priv/plugin_index/official.pub")

    name = opts[:name] || "Mydia"

    manifest_paths =
      crates_dir
      |> Path.join("*/manifest.json")
      |> Path.wildcard()
      |> Enum.sort()

    reject_duplicate_slugs(manifest_paths)

    entries = Enum.map(manifest_paths, &build_entry(&1, wasm_dir, out, base_url))

    File.mkdir_p!(out)
    index_path = Path.join(out, "index.json")
    catalog = %{"version" => 2, "name" => name, "public_key" => public_key, "plugins" => entries}
    File.write!(index_path, JSON.encode!(catalog))
    IO.puts("wrote #{length(entries)} plugin(s) to #{index_path}")
  end

  # The key line of a minisign .pub file, trimmed so a CRLF checkout cannot
  # embed a "\r" that Mydia would then fail to match against its pinned key.
  defp read_public_key(path) do
    lines =
      case File.read(path) do
        {:ok, text} -> String.split(text, "\n")
        {:error, reason} -> fail("cannot read #{path}: #{:file.format_error(reason)}")
      end

    key =
      lines
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "untrusted comment:")))
      |> List.first()

    case key do
      "RW" <> _ -> key
      nil -> fail("#{path} has no public key line")
      _ -> fail("#{path} is not a minisign public key")
    end
  end

  # Two crates with one slug would write the same package path, the second
  # silently replacing the first while both catalog entries survive.
  defp reject_duplicate_slugs(manifest_paths) do
    Enum.reduce(manifest_paths, %{}, fn path, seen ->
      slug = path |> File.read!() |> JSON.decode!() |> required("slug", path)

      case seen do
        %{^slug => first} ->
          fail("duplicate slug \"#{slug}\" in #{first} and #{path}")

        _ ->
          Map.put(seen, slug, path)
      end
    end)
  end

  defp build_entry(manifest_path, wasm_dir, out, base_url) do
    crate = manifest_path |> Path.dirname() |> Path.basename()
    manifest = manifest_path |> File.read!() |> JSON.decode!()

    slug = required(manifest, "slug", manifest_path)
    name = required(manifest, "name", manifest_path)
    version = required(manifest, "version", manifest_path)

    wasm_path = Path.join(wasm_dir, "#{crate}.wasm")

    bytes =
      case File.read(wasm_path) do
        {:ok, bytes} -> bytes
        {:error, reason} -> fail("cannot read #{wasm_path}: #{:file.format_error(reason)}")
      end

    relative = Path.join(["packages", slug, "#{version}.wasm"])
    dest = Path.join(out, relative)
    File.mkdir_p!(Path.dirname(dest))
    File.write!(dest, bytes)

    %{
      "slug" => slug,
      "name" => name,
      "version" => version,
      "description" => manifest["description"],
      "author" => manifest["author"],
      "package_url" => "#{base_url}/#{relative}",
      "integrity" => "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
      "manifest" => manifest
    }
  end

  defp required(manifest, key, path) do
    case manifest[key] do
      value when is_binary(value) and value != "" -> value
      _ -> fail("#{path} is missing \"#{key}\"")
    end
  end

  defp fail(message) do
    IO.puts(:stderr, "build_plugin_index: " <> message)
    System.halt(1)
  end
end

BuildPluginIndex.main(System.argv())
