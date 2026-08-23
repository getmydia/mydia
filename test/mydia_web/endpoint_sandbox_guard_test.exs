defmodule MydiaWeb.EndpointSandboxGuardTest do
  @moduledoc """
  Source-level guard for `MydiaWeb.Endpoint`.

  `Phoenix.Ecto.SQL.Sandbox` must only ever be compiled into the test
  environment: per the library's own documentation it should be wrapped in
  `if Application.compile_env(:mydia, :sql_sandbox) do ... end` so it is
  absent from every other build. A behavioural test can't exercise this
  directly, because in the test environment the plug is legitimately
  mounted. Instead this reads the endpoint source and asserts the plug
  declaration is nested inside that guard, and nowhere else unguarded.
  """

  use ExUnit.Case, async: true

  @endpoint_path Path.expand("../../lib/mydia_web/endpoint.ex", __DIR__)
  @guard_start ~r/^\s*if\s+Application\.compile_env\(:mydia,\s*:sql_sandbox\)\s+do\s*$/
  @plug_line ~r/^\s*plug\s+Phoenix\.Ecto\.SQL\.Sandbox\s*$/
  @block_end ~r/^\s*end\s*$/

  test "the SQL sandbox plug is only mounted behind the sql_sandbox compile-time flag" do
    lines = @endpoint_path |> File.read!() |> String.split("\n")

    guard_index = Enum.find_index(lines, &String.match?(&1, @guard_start))

    assert guard_index,
           "expected lib/mydia_web/endpoint.ex to guard the sandbox plug behind " <>
             "`if Application.compile_env(:mydia, :sql_sandbox) do`"

    remainder = Enum.drop(lines, guard_index + 1)
    end_offset = Enum.find_index(remainder, &String.match?(&1, @block_end))

    assert end_offset,
           "expected a matching `end` closing the sql_sandbox guard block"

    guarded_block = Enum.slice(remainder, 0, end_offset)

    assert Enum.any?(guarded_block, &String.match?(&1, @plug_line)),
           "expected `plug Phoenix.Ecto.SQL.Sandbox` inside the sql_sandbox guard block"

    lines_outside_guard =
      Enum.slice(lines, 0, guard_index) ++ Enum.slice(remainder, (end_offset + 1)..-1//1)

    refute Enum.any?(lines_outside_guard, &String.match?(&1, @plug_line)),
           "the sandbox plug must not also be mounted outside the sql_sandbox guard"
  end
end
