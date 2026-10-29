defmodule Mydia.Indexers.Cardigann.DotnetRegex do
  @moduledoc """
  Compiles a Cardigann definition's regular expression with PCRE2.

  Definitions are written for .NET's `Regex` (Prowlarr) and Go's `regexp`
  (Jackett's heritage). PCRE2 rejects some of their spellings, which are
  rewritten first:

  - `\\uXXXX` (.NET) becomes `\\x{XXXX}`;
  - `\\p{IsX}` becomes `\\p{X}`;
  - `(?P<name>` (Go) becomes `(?<name>`.
  """

  @spec to_pcre(String.t()) :: String.t()
  def to_pcre(pattern) when is_binary(pattern) do
    pattern
    # An odd run of backslashes before u is an escape; an even one is literal.
    |> then(&Regex.replace(~r/(?<!\\)((?:\\\\)*)\\u([0-9A-Fa-f]{4})/, &1, "\\1\\\\x{\\2}"))
    |> then(&Regex.replace(~r/\\p\{Is(\w+)\}/, &1, "\\p{\\1}"))
    |> String.replace("(?P<", "(?<")
  end

  @spec compile(String.t()) :: {:ok, Regex.t()} | {:error, term()}
  def compile(pattern) when is_binary(pattern),
    do: pattern |> to_pcre() |> Regex.compile([:unicode])
end
