defmodule Mydia.NoNestedRegexAttributesTest do
  @moduledoc """
  A module attribute in `lib/` may hold a regex, but never a collection of them.

  Under OTP 28 a compiled regex carries a `reference` in its `re_pattern` field.
  When `@attr` is injected into a function body the compiler has to escape that
  value into the AST, and Elixir 1.18 special-cases a `%Regex{}` sitting at the
  top level of the attribute while the generic path underneath it does not:

      @patterns [~r/a/, ~r/b/]
      def match?(s), do: Enum.any?(@patterns, &Regex.match?(&1, s))
      # ** (ArgumentError) cannot inject attribute @patterns into function/macro
      #    because cannot escape #Reference<0.3459598555.3953000449.246799>

  Elixir 1.19 escapes the nested case too, which is why this never fails where
  most people run the suite. The Nix release (`nix/packages/flake-module.nix`
  takes whatever Elixir `beam.packages.erlang_28` defaults to, currently 1.18)
  is the one build that still compiles on 1.18, so the whole class lands as a
  red `Test / NixOS Module` on master with every other job green. It did, on
  `e67579d35`, through `@hwaccel_failure_patterns` and `@profile_patterns`.

  Aligning the Nix build onto 1.19 would remove the constraint, but it means
  rebuilding every dep in `deps.nix` under a different compiler. Until someone
  does that, keep the collection in a private function: the regexes are then
  ordinary literals in a function body, which both versions handle.
  """
  use ExUnit.Case, async: true

  @sources Path.wildcard("lib/**/*.ex")

  test "no module attribute in lib/ holds a collection of regexes" do
    offenders =
      Enum.flat_map(@sources, fn path ->
        path
        |> File.read!()
        |> nested_regex_attributes()
        |> Enum.map(&"#{path}: @#{&1}")
      end)

    assert offenders == [],
           """
           These module attributes hold a collection containing a regex, which
           fails to compile on Elixir 1.18 the moment the attribute is used in a
           function body:

           #{Enum.map_join(offenders, "\n", &"  #{&1}")}

           Move the collection into a private function returning the same list.
           """
  end

  test "the scan recognises the shapes that actually broke the build" do
    assert nested_regex_attributes("""
             @patterns [
               ~r/a/i,
               ~r/b/i
             ]
           """) == ["patterns"]

    assert nested_regex_attributes(~S"""
             @profiles [{~r/A/, :a}, {~r/B/, :b}]
           """) == ["profiles"]

    assert nested_regex_attributes(~S"""
             @lookup %{a: ~r/A/}
           """) == ["lookup"]
  end

  test "the scan covers the other ways a regex reaches an attribute" do
    # ~R builds the same struct with interpolation and escapes turned off, and
    # it is the natural sigil for a pattern full of backslashes, so it is what
    # a future author of one of these lists is most likely to reach for.
    assert nested_regex_attributes(~S"""
             @patterns [~R/a\d/, ~R/b/]
           """) == ["patterns"]

    # Any sigil delimiter, not only //.
    assert nested_regex_attributes(~S"""
             @patterns [~r{a}, ~r|b|]
           """) == ["patterns"]

    # An attribute's value is evaluated at compile time, so a built regex lands
    # in it carrying a reference exactly as a sigil does.
    assert nested_regex_attributes(~S"""
             @patterns [Regex.compile!("a")]
           """) == ["patterns"]
  end

  test "the scan leaves a bare regex attribute alone" do
    assert nested_regex_attributes(~S"""
             @pattern ~r/^(disc|disk)\d+$/i
           """) == []

    assert nested_regex_attributes(~S"""
             @pattern ~R/^(disc|disk)\d+$/i
           """) == []
  end

  # `~r` and `~R` build the same struct -- the uppercase sigil only turns off
  # interpolation and escape processing -- and an attribute's value is
  # evaluated at compile time, so a `Regex.compile` call in one lands a
  # reference there just as a sigil does. All three forms count.
  @regex_forms ~r/~[rR][\/|"'({\[<]|Regex\.compile/

  # Matches `@name` followed by an opening `[`, `{` or `%{` on the same line,
  # then scans forward to the line that closes it at the same indentation. A
  # regex anywhere in that span is the failure. Deliberately textual:
  # `Code.string_to_quoted/1` would expand the sigils and hit the very escape
  # error this guard exists to keep out of the tree.
  defp nested_regex_attributes(source) do
    lines = String.split(source, "\n")

    lines
    |> Enum.with_index()
    |> Enum.flat_map(fn {line, index} ->
      case Regex.run(~r/^(\s*)@([a-z_][a-zA-Z0-9_]*)\s+(%?[\[{].*)$/, line) do
        [_, indent, name, rest] ->
          span = collect_span(lines, index, rest, indent)
          if Regex.match?(@regex_forms, span), do: [name], else: []

        nil ->
          []
      end
    end)
  end

  # The attribute's value, from its opening bracket to the line that closes it.
  # A single-line attribute closes on its own line; a multi-line one closes on
  # the first later line whose only content is the closing bracket at the
  # attribute's own indentation.
  defp collect_span(lines, index, rest, indent) do
    if balanced?(rest) do
      rest
    else
      lines
      |> Enum.drop(index + 1)
      |> Enum.take_while(&(not closing_line?(&1, indent)))
      |> Enum.join("\n")
      |> then(&(rest <> "\n" <> &1))
    end
  end

  defp balanced?(text) do
    opens = count_chars(text, ["[", "{"])
    closes = count_chars(text, ["]", "}"])
    opens <= closes
  end

  defp count_chars(text, chars) do
    text |> String.graphemes() |> Enum.count(&(&1 in chars))
  end

  defp closing_line?(line, indent) do
    Regex.match?(~r/^#{indent}[\]}]\s*$/, line)
  end
end
