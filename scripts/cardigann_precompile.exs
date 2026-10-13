# Precompiles the Cardigann guest for CI (.github/workflows/cardigann-cwasm.yml).
#
#   elixir -pa "_build/prod/lib/*/ebin" scripts/cardigann_precompile.exs <guest.wasm> <out-dir> <asset-name>
#
# Run from the app root, outside the application, with only the compiled deps on
# the code path, inside the Dockerfile's `cwasm` stage: the same Alpine base,
# Rust toolchain and patched Wasmex NIF as the release image. Writes <asset-name>
# (gzipped) and <asset-name minus .gz>.sha256 (of the decompressed file), after
# checking that the native runtime engine accepts what the portable CI engine
# wrote.
#
# This lives outside native/cardigann_guest/ on purpose: editing it must not
# change the guest source hash and trigger a new guest release.
Code.require_file("lib/mydia/indexers/cardigann/wasm/engine_config.ex")
alias Mydia.Indexers.Cardigann.Wasm.EngineConfig

[wasm, out, asset] = System.argv()

# The asset name carries the wasmtime version the release tag was computed from.
# Refuse to write a file under a name that disagrees with the NIF compiling it.
cargo = "deps/wasmex/native/wasmex/Cargo.toml"

wasmtime =
  with {:ok, toml} <- File.read(cargo),
       [_, v] <- Regex.run(~r/^wasmtime\s*=\s*"=?([0-9.]+)"/m, toml) do
    v
  else
    _ -> raise "could not read the wasmtime version from #{cargo}"
  end

unless String.contains?(asset, "-wasmtime#{wasmtime}-") do
  raise "asset name #{asset} does not match the wasmtime #{wasmtime} this Wasmex was built with"
end

bytes = File.read!(wasm)
File.mkdir_p!(out)
cwasm = Path.join(out, String.replace_suffix(asset, ".gz", ""))

{us, :ok} =
  :timer.tc(fn ->
    Wasmex.Engine.precompile_component_to_file(EngineConfig.ci_engine(), bytes, cwasm)
  end)

IO.puts("precompiled in #{div(us, 1000)} ms, #{File.stat!(cwasm).size} bytes")

{:ok, store} =
  Wasmex.Components.Store.new_wasi(
    %Wasmex.Wasi.WasiP2Options{inherit_stdin: false, inherit_stdout: false, inherit_stderr: false},
    nil,
    EngineConfig.runtime_engine()
  )

case Wasmex.Components.Component.deserialize_file(store, cwasm, bytes) do
  {:ok, _} -> IO.puts("the native runtime engine accepts it")
  {:error, reason} -> raise "the native runtime engine rejects the CI .cwasm: #{inspect(reason)}"
end

sha = :crypto.hash(:sha256, File.read!(cwasm)) |> Base.encode16(case: :lower)
File.write!(cwasm <> ".sha256", sha <> "\n")
{_, 0} = System.cmd("gzip", ["-9", "-n", cwasm])
IO.puts("#{asset} sha256 (decompressed) #{sha}")
