defmodule Mix.Tasks.Compile.Plugins do
  @moduledoc """
  Builds the bundled WASM plugin guests under `plugins/*/` into `priv/plugins/`.

  Mirrors how `use Rustler` lands the p2p NIF in `priv/native/`, but as a real
  `Mix.Task.Compiler` registered (appended) in `mix.exs` `compilers/0` — it runs
  after `:elixir` because the task module lives in `lib/` and isn't loadable
  until the app is compiled — so the guests build transparently on every
  `mix compile` in dev, test, CI, and the Docker image build. The compiled `.wasm` is gitignored — source under
  `plugins/*/` is the only truth (U1–U3 of the built-in-plugins plan).

  ## Incremental by content digest, not mtime

  Each crate's source tree (everything but `target/`) is hashed; the manifest
  caches `{source_digest, output_sha256}` per crate. A crate is skipped (no cargo)
  only when the source digest matches **and** the artifact on disk hashes to the
  recorded output — so a stale or foreign `priv/plugins/*.wasm` triggers a
  rebuild instead of being silently reused (the manifest lives in `_build`, which
  a shared build cache can pair with a per-checkout output dir). The digest is
  content-based, so a `git checkout`/`bisect` that rewinds source correctly
  triggers a rebuild — an mtime guard would not (a gitignored artifact can be
  newer than older source).

  ## Loud skip on a missing toolchain

  Guests are WebAssembly **components**, built for `wasm32-wasip2` against the
  canonical WIT contract (the SDK's `wit-bindgen` is a cargo dependency, so no
  system binding-generator is needed). When `cargo` or the `wasm32-wasip2` target
  is unavailable the guests cannot be rebuilt. Setting `MYDIA_PREBUILT_PLUGINS=1`
  skips building altogether (used in the Docker `builder` stage after copying
  artifacts from its `plugins` stage). Rather than hard-failing — a
  toolchain-less contributor and
  the Nix package build legitimately lack the target — the compiler no-ops, but
  it **never skips silently**: it emits a loud `Mix.shell/0` warning that names
  what was skipped and whether the existing `priv/plugins/*.wasm` is merely
  *stale* (outputs present, not rebuilt) or outright *missing* (the plugin will
  not load). The release guard lives in the Docker builders, which assert
  `priv/plugins/*.wasm` exists after `mix compile` (see Dockerfile /
  Dockerfile.e2e), so an image can never ship without the bundled artifact.
  """

  use Mix.Task.Compiler

  @recursive false
  @target "wasm32-wasip2"
  @manifest_vsn 2

  @impl Mix.Task.Compiler
  def run(_argv) do
    if System.get_env("MYDIA_PREBUILT_PLUGINS") == "1" do
      {:noop, []}
    else
      crates = crates()

      cond do
        crates == [] ->
          {:noop, []}

        (reason = toolchain_gap()) != nil ->
          on_toolchain_gap(reason, crates)

        true ->
          build_all(crates)
      end
    end
  end

  @impl Mix.Task.Compiler
  def manifests, do: [manifest_path()]

  @impl Mix.Task.Compiler
  def clean do
    File.rm(manifest_path())
    :ok
  end

  # ── Crate discovery ───────────────────────────────────────────────────────

  defp crates do
    "plugins"
    |> Path.expand(File.cwd!())
    |> Path.join("*/Cargo.toml")
    |> Path.wildcard()
    |> Enum.map(&Path.dirname/1)
    |> Enum.sort()
  end

  # ── Toolchain probing ─────────────────────────────────────────────────────

  # Returns nil when the toolchain can build wasm, or a human reason string when
  # it cannot. We probe the active rust toolchain's own sysroot rather than
  # asking `rustup`: a foreign `rustup` on PATH (e.g. a CI runner's system
  # rustup sitting alongside a Nix/devenv `cargo`) reports targets for ITS
  # toolchain, not the `cargo`/`rustc` actually in use — a false negative that
  # silently skips the guest build. `<rustc --print sysroot>/lib/rustlib/<target>`
  # is exactly where `cargo build --target` looks for the target std, so the
  # check is correct for rustup- and Nix-managed toolchains alike.
  defp toolchain_gap do
    cond do
      System.find_executable("cargo") == nil -> "cargo not found on PATH"
      wasm_target_installed?() -> nil
      true -> "the #{@target} rust target is not installed"
    end
  end

  defp wasm_target_installed? do
    case System.cmd("rustc", ["--print", "sysroot"], stderr_to_stdout: true) do
      {sysroot, 0} ->
        File.dir?(Path.join([String.trim(sysroot), "lib", "rustlib", @target]))

      _ ->
        false
    end
  rescue
    _ -> false
  end

  # The compiler graceful-skips a missing wasm toolchain (no-op) rather than
  # hard-failing: the Nix package build and toolchain-less contributors
  # legitimately lack the target, and forcing a hard error there would break
  # those builds. The skip is never silent, though — it warns loudly via
  # Mix.shell().error/1, distinguishing stale outputs from missing ones, so a
  # stale priv/plugins/*.wasm can't be used without notice. The release guard is
  # the Docker builders asserting the artifact exists after `mix compile`.
  defp on_toolchain_gap(reason, crates) do
    Mix.shell().error(toolchain_gap_message(reason, missing_outputs(crates)))
    {:noop, []}
  end

  # The build outputs (relative paths) that do not yet exist for the given
  # crates. Empty means every guest already has a (possibly stale) artifact.
  defp missing_outputs(crates) do
    for crate <- crates,
        rel = "priv/plugins/#{Path.basename(crate)}.wasm",
        not File.exists?(Path.expand(rel, File.cwd!())),
        do: rel
  end

  # Builds the loud-skip warning. Pure (no IO) for testing. `missing_outputs` is
  # the list of artifacts absent from disk; when empty, the existing ones may be
  # stale because they were not rebuilt.
  @doc false
  def toolchain_gap_message(reason, missing_outputs) do
    fix =
      "Install the #{@target} target (`rustup target add #{@target}`) or rebuild " <>
        "your dev image, then re-run `mix compile`."

    detail =
      case missing_outputs do
        [] ->
          "Bundled plugin guests were NOT rebuilt; the existing priv/plugins/*.wasm " <>
            "may be STALE."

        missing ->
          "MISSING artifacts: #{Enum.join(missing, ", ")} — those plugins will not load."
      end

    "[plugins] WARNING: wasm toolchain unavailable (#{reason}). #{detail} #{fix}"
  end

  # ── Build ─────────────────────────────────────────────────────────────────

  defp build_all(crates) do
    cache = read_manifest()

    {results, new_cache} =
      Enum.map_reduce(crates, cache, fn crate, acc ->
        {result, entry} = build_crate(crate, acc)
        {result, Map.put(acc, crate, entry)}
      end)

    write_manifest(new_cache)

    cond do
      Enum.find(results, &match?({:error, _}, &1)) ->
        {:error, [elem(Enum.find(results, &match?({:error, _}, &1)), 1)]}

      Enum.any?(results, &(&1 == :built)) ->
        {:ok, []}

      true ->
        {:noop, []}
    end
  end

  # Returns {{:error, diagnostic} | :built | :unchanged | :skipped, cache_entry}
  # where a cache entry is `{source_digest, output_sha256}`.
  defp build_crate(crate, cache) do
    name = Path.basename(crate)
    digest = source_digest(crate)
    output = Path.expand(Path.join("priv/plugins", "#{name}.wasm"), File.cwd!())
    previous = Map.get(cache, crate)

    if output_fresh?(previous, digest, output) do
      {:unchanged, previous}
    else
      result = compile_crate(crate, name, output)
      {result, cache_entry(result, digest, output, previous)}
    end
  end

  # A crate is unchanged only when its source digest matches AND the artifact on
  # disk is byte-for-byte the one that digest produced. Validating the output's
  # *content* (not just `File.exists?/1`) is what stops a stale or foreign
  # priv/plugins/*.wasm from being silently accepted — e.g. a shared build-cache
  # manifest (in _build) paired with a per-checkout output dir, where the digest
  # matches but this checkout's artifact is stale. Public for testing only.
  @doc false
  def output_fresh?({cached_digest, output_sha}, digest, output) do
    cached_digest == digest and File.exists?(output) and sha256_file(output) == output_sha
  end

  def output_fresh?(_previous, _digest, _output), do: false

  # The manifest entry to record after a build attempt. A real build or a trusted
  # unchanged records the new digest + the output's hash; a skip or error keeps
  # the previous entry so a later run with a working toolchain still rebuilds.
  defp cache_entry(result, digest, output, previous) do
    if result in [:built, :unchanged] and File.exists?(output) do
      {digest, sha256_file(output)}
    else
      previous
    end
  end

  defp sha256_file(path) do
    :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
  end

  defp compile_crate(crate, name, output) do
    Mix.shell().info("[plugins] compiling #{name} -> priv/plugins/#{name}.wasm")

    case System.cmd("cargo", ["build", "--release", "--target", @target],
           cd: crate,
           stderr_to_stdout: true
         ) do
      {_out, 0} ->
        copy_if_changed(crate, name, output)

      {out, _code} ->
        if wasm_target_missing?(out) do
          # A cargo without the wasm32 std (apk/distro/Nix cargo, no rustup) only
          # surfaces the gap at build time. Treat it as a skip, not a hard error,
          # so it matches the toolchain-gap path above — but warn loudly so a
          # stale or missing priv/plugins/#{name}.wasm can't pass unnoticed.
          Mix.shell().error(
            "[plugins] WARNING: skipped #{name} — #{@target} target not available; " <>
              "priv/plugins/#{name}.wasm may be stale or missing"
          )

          :skipped
        else
          # A real guest build error (e.g. a server-only crate). Surface cargo's
          # stderr verbatim — wasm32 errors are otherwise cryptic.
          {:error, diagnostic("cargo build failed for #{name}:\n#{out}")}
        end
    end
  end

  # True when cargo output indicates the wasm32 target/std is not installed (vs a
  # genuine source error). Public for testing only.
  @doc false
  def wasm_target_missing?(output) do
    String.contains?(output, "target may not be installed") or
      String.contains?(output, "rustup target add") or
      String.contains?(output, "can't find crate for `core`") or
      String.contains?(output, "can't find crate for `std`")
  end

  # Copy only when the freshly built bytes differ from what's on disk, so an
  # unchanged rebuild doesn't churn the (gitignored) artifact.
  defp copy_if_changed(crate, name, output) do
    built = Path.join([crate, "target", @target, "release", "#{name}.wasm"])

    cond do
      not File.exists?(built) ->
        {:error, diagnostic("cargo reported success but #{built} is missing")}

      File.exists?(output) and File.read!(built) == File.read!(output) ->
        :unchanged

      true ->
        File.mkdir_p!(Path.dirname(output))
        File.cp!(built, output)
        :built
    end
  end

  # ── Source digest (content-based, target/ excluded) ───────────────────────

  # Content digest of a crate's source tree (everything but `target/`). Public
  # for testing only — the digest is content-based so it survives `git
  # checkout`/`bisect` correctly, unlike an mtime comparison.
  @doc false
  def source_digest(crate) do
    crate
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.reject(&(File.dir?(&1) or String.contains?(&1, "/target/")))
    |> Enum.sort()
    |> Enum.reduce(:crypto.hash_init(:sha256), fn path, acc ->
      rel = Path.relative_to(path, crate)
      :crypto.hash_update(acc, rel <> "\0" <> File.read!(path))
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  # ── Manifest ──────────────────────────────────────────────────────────────

  defp manifest_path, do: Path.join(Mix.Project.manifest_path(), "compile.plugins")

  defp read_manifest do
    case File.read(manifest_path()) do
      {:ok, bin} ->
        case safe_binary_to_term(bin) do
          {@manifest_vsn, map} when is_map(map) -> map
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp write_manifest(map) do
    File.mkdir_p!(Path.dirname(manifest_path()))
    File.write!(manifest_path(), :erlang.term_to_binary({@manifest_vsn, map}))
  end

  defp safe_binary_to_term(bin) do
    :erlang.binary_to_term(bin, [:safe])
  rescue
    _ -> nil
  end

  # ── Diagnostics ───────────────────────────────────────────────────────────

  defp diagnostic(message) do
    %Mix.Task.Compiler.Diagnostic{
      compiler_name: "plugins",
      file: Path.expand("plugins", File.cwd!()),
      message: message,
      position: nil,
      severity: :error
    }
  end
end
