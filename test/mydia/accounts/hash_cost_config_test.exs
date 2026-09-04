defmodule Mydia.Accounts.HashCostConfigTest do
  @moduledoc """
  Password hashing cost may be lowered in `config/test.exs` and nowhere else.

  bcrypt and Argon2 default to production cost, which is ~170ms and ~64ms per
  hash on a development machine and closer to 300ms and 120ms on a CI runner.
  135 test files create users, 122 of them inside a per-test `setup`, so at
  production cost the suite spends several minutes doing nothing but hashing.
  `config/test.exs` therefore sets `log_rounds: 4` and `t_cost: 1, m_cost: 8`.

  Those values are catastrophic in production: bcrypt at 4 rounds is roughly
  200x cheaper to attack than at 12. The failure mode this guard closes is
  someone hitting a slow `mix mydia.user add` or a slow release task, moving the
  block up into `config/config.exs` to "fix" it, and shipping 4-round password
  hashes with CI green.

  Same shape as `Mydia.Repo.Migrations.NoVarcharColumnsTest`: read the source,
  fail with the reason and the fix.
  """

  use ExUnit.Case, async: true

  # `config/runtime.exs` is evaluated in every environment including :prod, so it
  # is checked alongside the compile-time files.
  @cost_keys ~w(log_rounds t_cost m_cost)

  # Anchored like `Mydia.Repo.Migrations.NoVarcharColumnsTest`'s @declarations:
  # the key must open a keyword pair (line start, or after a comma as in
  # `config :bcrypt_elixir, log_rounds: 4`), so an unrelated `log_rounds:`
  # inside a string literal or heredoc doesn't trip the guard.
  @cost_key_patterns Enum.map(@cost_keys, &Regex.compile!("(?:^|,)\\s*#{Regex.escape(&1)}:"))

  describe "hashing cost configuration" do
    test "no config file outside config/test.exs sets a hashing cost" do
      offenders =
        config_files()
        |> Enum.reject(&(Path.basename(&1) == "test.exs"))
        |> Enum.flat_map(&cost_key_lines/1)
        |> Enum.sort()

      assert offenders == [],
             """
             These config files set a password hashing cost:

               #{Enum.join(offenders, "\n  ")}

             bcrypt and Argon2 cost may only be lowered in config/test.exs.
             `config/config.exs` and `config/runtime.exs` are evaluated in
             production, so a cost set there weakens real password and API-key
             hashing while every test stays green.

             If a dev-only task is too slow, lower the cost in config/dev.exs
             ONLY if you accept that dev-created credentials are weakly hashed,
             and never in config.exs, prod.exs or runtime.exs.
             """
    end

    test "config/test.exs still sets both costs" do
      source = File.read!("config/test.exs")

      # Presence checks alone pass if someone lowers the numbers back toward
      # production cost (log_rounds: 12) or drops t_cost/m_cost entirely, so
      # pin the exact values this suite relies on.
      assert source =~ "config :bcrypt_elixir, log_rounds: 4",
             "config/test.exs no longer pins bcrypt to log_rounds: 4; the suite will spend " <>
               "minutes hashing at production cost"

      assert source =~ "config :argon2_elixir, t_cost: 1, m_cost: 8",
             "config/test.exs no longer pins Argon2 to t_cost: 1, m_cost: 8; the suite will " <>
               "spend minutes hashing at production cost"

      # The source-text asserts above only catch an edit to this file. They
      # cannot catch an override applied from somewhere else (loaded after
      # this file, or set at runtime) that changes the *effective* cost
      # without ever touching config/test.exs, so assert what's actually
      # loaded into application env for the running test suite too.
      assert Application.get_env(:bcrypt_elixir, :log_rounds) == 4,
             "bcrypt_elixir's effective log_rounds is not 4; something outside " <>
               "config/test.exs is overriding it and the suite will spend minutes hashing"

      assert Application.get_env(:argon2_elixir, :t_cost) == 1,
             "argon2_elixir's effective t_cost is not 1; something outside " <>
               "config/test.exs is overriding it and the suite will spend minutes hashing"

      assert Application.get_env(:argon2_elixir, :m_cost) == 8,
             "argon2_elixir's effective m_cost is not 8; something outside " <>
               "config/test.exs is overriding it and the suite will spend minutes hashing"
    end

    test "the config glob actually matches files" do
      assert config_files() != [], "no config files found; the wildcard or CWD is wrong"
    end
  end

  defp config_files, do: Path.wildcard("config/*.exs")

  defp cost_key_lines(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reject(fn {line, _n} -> String.starts_with?(String.trim(line), "#") end)
    |> Enum.filter(fn {line, _n} -> Enum.any?(@cost_key_patterns, &Regex.match?(&1, line)) end)
    |> Enum.map(fn {line, n} -> "#{Path.basename(path)}:#{n}: #{String.trim(line)}" end)
  end
end
