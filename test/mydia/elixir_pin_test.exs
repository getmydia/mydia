defmodule Mydia.ElixirPinTest do
  @moduledoc """
  .elixir-version is the single source of truth for the Elixir minor, read by
  devenv.nix, nix/packages/flake-module.nix and the "Check / Elixir Pin" CI job.
  This pins its format so a hand edit cannot quietly break every Nix eval.
  """
  use ExUnit.Case, async: true

  test "it holds exactly one major.minor version" do
    contents = File.read!(Path.join(File.cwd!(), ".elixir-version"))

    assert String.match?(contents, ~r/\A\d+\.\d+\n?\z/),
           ".elixir-version must be a bare major.minor, got: #{inspect(contents)}"
  end

  test "the running Elixir matches the pin" do
    pinned = ".elixir-version" |> File.read!() |> String.trim()
    running = System.version() |> String.split(".") |> Enum.take(2) |> Enum.join(".")

    assert running == pinned,
           "running Elixir #{System.version()} does not match .elixir-version #{pinned}"
  end
end
