defmodule Mydia.Config.DependencyCompileEnvTest do
  @moduledoc """
  No dependency may read compile-time configuration this project sets.

  `Application.compile_env/3` bakes the value into the *dependency* at the
  moment the dependency is compiled, and records what it saw in the
  dependency's `.app` file. Elixir then re-checks that record against the
  running configuration on every boot, and aborts if the two disagree.

  Docker and `mix` compile dependencies in-tree, with `config/config.exs`
  present, so both agree and nothing is visible. `deps.nix` builds each hex
  dependency as its own isolated derivation that never sees this project's
  config, so the dependency compiles against its default while the release's
  `sys.config` carries ours. The result is a release that aborts during boot
  rather than a build that fails where anyone can see it.

  That shipped: `config :mime, :types` reached `v0.14.0-beta.4` and left the
  NixOS module restart-looping, while Docker and the player artifacts in the
  same release were fine. The NixOS VM tests that would have caught it run on
  push only, so no pull request could have.

  This test costs milliseconds and runs on every pull request, which the VM
  tests do not.
  """
  use ExUnit.Case, async: true

  test "no dependency reads compile-time configuration this project sets" do
    config = Config.Reader.read!("config/config.exs", env: :prod)

    violations =
      for {app, key_path} <- dependency_compile_env_reads(),
          configured?(config, app, key_path),
          do: {app, key_path}

    assert violations == [], failure_message(violations)
  end

  # Every `Application.compile_env/3` call recorded by a compiled dependency.
  #
  # The application named in an entry is not always the application that
  # recorded it: `wasmex` records reads of `:rustler_precompiled`, so the
  # entry's own app is what matters, not the file it came from.
  #
  # Entries naming `:mydia` are excluded. Those come from
  # `Application.compile_env(@otp_app, ...)` inside dependency macros, which
  # `Phoenix.Endpoint` uses, and which expand into this project's own modules.
  # Nix compiles the `mydia` application itself with this project's config, so
  # they can never disagree.
  defp dependency_compile_env_reads do
    Mix.Project.build_path()
    |> Path.join("lib/*/ebin/*.app")
    |> Path.wildcard()
    |> Enum.flat_map(fn file ->
      {:ok, [{:application, _name, keyword}]} = :file.consult(String.to_charlist(file))
      Keyword.get(keyword, :compile_env, [])
    end)
    |> Enum.map(fn {app, key_path, _compile_time_value} -> {app, key_path} end)
    |> Enum.reject(fn {app, _key_path} -> app == :mydia end)
    |> Enum.uniq()
  end

  # `config/config.exs` ends with an `import_config` of the environment file, so
  # reading it with `env: :prod` is the whole compile-time configuration a
  # release is built with. `runtime.exs` is deliberately not consulted: it is
  # applied after compilation and cannot participate in this mismatch.
  defp configured?(config, app, key_path) do
    case Keyword.fetch(config, app) do
      :error -> false
      {:ok, app_config} -> traverse(app_config, key_path)
    end
  end

  defp traverse(_value, []), do: true

  defp traverse(config, [key | rest]) when is_list(config) do
    case Keyword.fetch(config, key) do
      :error -> false
      {:ok, value} -> traverse(value, rest)
    end
  end

  # A non-list stops the walk: the path is not reachable, so nothing is set.
  defp traverse(_value, _key_path), do: false

  defp failure_message(violations) do
    listed =
      Enum.map_join(violations, "\n", fn {app, key_path} ->
        "  * #{inspect(app)}, key #{inspect(key_path)}"
      end)

    """
    A dependency reads compile-time configuration this project sets:

    #{listed}

    A builder that compiles each dependency in its own isolated derivation,
    which `deps.nix` and the Nix package do, cannot see `config/config.exs`.
    The dependency compiles against its default, the release's `sys.config`
    carries this project's value, and `Config.Provider.boot/2` aborts the
    release during boot. The NixOS module restart-loops; nothing fails at
    build time.

    Prefer not configuring the dependency at all. When the extension is
    genuinely required, it has to be reproduced inside that dependency's own
    derivation in nix/packages/flake-module.nix, and locally it needs
    `mix deps.clean <app> --build` before the change takes effect.

    This shipped once, as `config :mime, :types` in v0.14.0-beta.4.
    """
  end
end
