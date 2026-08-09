defmodule Mydia.Settings.CustomFormats.Matcher do
  @moduledoc """
  Compiles and applies custom format patterns against release titles.

  Pure: no database access, no application config. Every function takes a
  plain string and already-compiled patterns, which is what lets the upgrade
  path reuse this later against a stored file name (see the spec's Deferred
  section).

  ## Why `:re` directly instead of `Regex`

  Patterns are operator-authored, so a catastrophic one could otherwise
  backtrack until an Oban job dies. `:re.run/3` accepts `{:match_limit, n}`,
  which bounds backtracking; `Regex.match?/2` does not expose it. With
  `:report_errors`, exhausting the limit surfaces as `{:error, :match_limit}`
  rather than being indistinguishable from a genuine miss, so it can be logged.

  Patterns compile with `:caseless`, so matching is always case-insensitive and
  format authors must not add inline `(?i)` flags.
  """

  require Logger

  @compile_opts [:caseless, :unicode]
  @match_opts [
    {:match_limit, 10_000},
    {:match_limit_recursion, 10_000},
    {:capture, :none},
    :report_errors
  ]

  @type compiled_format :: %{
          slug: String.t(),
          name: String.t(),
          score: integer(),
          reject: boolean(),
          patterns: [:re.mp()]
        }

  @type score_result :: %{score: integer(), reject: boolean(), matched: [String.t()]}

  @doc """
  Compiles one pattern. Returns a human-readable message on failure, suitable
  for surfacing in a changeset error.
  """
  @spec compile_pattern(String.t()) :: {:ok, :re.mp()} | {:error, String.t()}
  def compile_pattern(pattern) when is_binary(pattern) do
    case :re.compile(pattern, @compile_opts) do
      {:ok, mp} ->
        {:ok, mp}

      # :re returns the reason as a charlist, not a binary.
      {:error, {reason, at}} ->
        {:error, "#{List.to_string(reason)} at position #{at}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  def compile_pattern(_), do: {:error, "pattern must be a string"}

  @doc """
  Compiles a list of patterns, failing on the first bad one.
  """
  @spec compile_patterns([String.t()]) :: {:ok, [:re.mp()]} | {:error, String.t()}
  def compile_patterns(patterns) when is_list(patterns) do
    Enum.reduce_while(patterns, {:ok, []}, fn pattern, {:ok, acc} ->
      case compile_pattern(pattern) do
        {:ok, mp} -> {:cont, {:ok, [mp | acc]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
    |> case do
      {:ok, compiled} -> {:ok, Enum.reverse(compiled)}
      {:error, message} -> {:error, message}
    end
  end

  def compile_patterns(_), do: {:error, "patterns must be a list"}

  @doc """
  True when any of the format's patterns match the title.

  A pattern that exhausts the match limit is treated as a miss and logged, so
  one pathological format degrades to inert instead of stalling a search.
  """
  @spec matches?(String.t(), compiled_format()) :: boolean()
  def matches?(title, %{patterns: patterns, name: name}) when is_binary(title) do
    Enum.any?(patterns, fn mp ->
      case :re.run(title, mp, @match_opts) do
        :match ->
          true

        :nomatch ->
          false

        {:error, reason} ->
          Logger.warning(
            "[CustomFormats] pattern for #{name} aborted with #{inspect(reason)} on " <>
              "#{String.slice(title, 0, 80)}; treating as no match"
          )

          false
      end
    end)
  end

  def matches?(_title, _format), do: false

  @doc """
  Scores a title against resolved formats.

  Rejecting formats contribute no score. The caller decides what to do with
  `:reject`; this function only reports it.
  """
  @spec score_title(String.t(), [compiled_format()]) :: score_result()
  def score_title(title, formats) when is_binary(title) and is_list(formats) do
    matched = Enum.filter(formats, &matches?(title, &1))

    %{
      score: matched |> Enum.reject(& &1.reject) |> Enum.map(& &1.score) |> Enum.sum(),
      reject: Enum.any?(matched, & &1.reject),
      matched: Enum.map(matched, & &1.name)
    }
  end

  def score_title(_title, _formats), do: %{score: 0, reject: false, matched: []}
end
