defmodule Mydia.BeamPinTest do
  @moduledoc """
  .elixir-version and .otp-version are the single sources of truth for the
  Elixir minor and the OTP major. beam-version.nix reads both (and through it
  devenv.nix and nix/packages/flake-module.nix), and so does the
  "Check / BEAM Pin" CI job. This pins their format so a hand edit cannot
  quietly break every Nix eval, and asserts the running VM is the pinned pair.
  """
  use ExUnit.Case, async: true

  defp pin(file), do: File.cwd!() |> Path.join(file) |> File.read!()

  test ".elixir-version holds exactly one major.minor version" do
    contents = pin(".elixir-version")

    assert String.match?(contents, ~r/\A\d+\.\d+\n?\z/),
           ".elixir-version must be a bare major.minor, got: #{inspect(contents)}"
  end

  test "the running Elixir matches the pin" do
    pinned = String.trim(pin(".elixir-version"))
    running = System.version() |> String.split(".") |> Enum.take(2) |> Enum.join(".")

    assert running == pinned,
           "running Elixir #{System.version()} does not match .elixir-version #{pinned}"
  end

  test ".otp-version holds exactly one major version" do
    contents = pin(".otp-version")

    assert String.match?(contents, ~r/\A\d+\n?\z/),
           ".otp-version must be a bare major, got: #{inspect(contents)}"
  end

  test "the running OTP matches the pin" do
    pinned = String.trim(pin(".otp-version"))
    running = System.otp_release()

    assert running == pinned,
           "running OTP #{running} does not match .otp-version #{pinned}"
  end
end
