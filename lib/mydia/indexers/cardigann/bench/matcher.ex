defmodule Mydia.Indexers.Cardigann.Bench.Matcher do
  @moduledoc """
  Decides whether two benchmark releases are the same release, and scores two
  release sets against each other.

  Two releases match when their normalised titles are equal and either

    * both carry an info hash and the hashes are equal, or
    * both carry a size and the sizes are within 1% of the larger one.

  Size 0 means "unknown" on the oracle side and 0 on the Mydia side, so 0 is
  normalised to nil on both. When neither side carries a hash or a size there is
  nothing that could contradict the title, and the title alone matches.

  This is the strict rule, the one the merge gate uses. With `lenient: true` a
  size known on only one side also counts as a size match. That is a diagnostic:
  it shows where agreement hinges on an engine not reporting a size.
  """

  alias Mydia.Indexers.Cardigann.Bench.Release

  @size_tolerance 0.01

  @spec same?(Release.t(), Release.t(), keyword()) :: boolean()
  def same?(%Release{} = a, %Release{} = b, opts \\ []) do
    normalize_title(a.title) == normalize_title(b.title) and
      evidence_matches?(a, b, Keyword.get(opts, :lenient, false))
  end

  @doc """
  Jaccard similarity of two release lists under greedy one-to-one matching:
  `matched / (|a| + |b| - matched)`. Two empty lists are identical (1.0).
  """
  @spec jaccard([Release.t()], [Release.t()], keyword()) :: float()
  def jaccard(a, b, opts \\ [])
  def jaccard([], [], _opts), do: 1.0

  def jaccard(a, b, opts) do
    %{matched: matched, only_left: left, only_right: right} = pair(a, b, opts)
    union = matched + length(left) + length(right)
    matched / union
  end

  @doc "The releases present on only one side after one-to-one matching."
  @spec diff([Release.t()], [Release.t()], keyword()) :: %{
          only_left: [Release.t()],
          only_right: [Release.t()]
        }
  def diff(a, b, opts \\ []) do
    %{only_left: left, only_right: right} = pair(a, b, opts)
    %{only_left: left, only_right: right}
  end

  defp pair(left, right, opts) do
    {pool, matched, unmatched_left} =
      Enum.reduce(left, {right, 0, []}, fn release, {pool, count, lonely} ->
        case take_match(pool, release, opts) do
          {:ok, rest} -> {rest, count + 1, lonely}
          :error -> {pool, count, [release | lonely]}
        end
      end)

    %{matched: matched, only_left: Enum.reverse(unmatched_left), only_right: pool}
  end

  defp take_match(pool, release, opts) do
    case Enum.find_index(pool, &same?(release, &1, opts)) do
      nil -> :error
      index -> {:ok, List.delete_at(pool, index)}
    end
  end

  defp evidence_matches?(a, b, lenient?) do
    {hash_a, hash_b, size_a, size_b} = {hash(a), hash(b), size(a), size(b)}

    same_hash?(hash_a, hash_b) or size_evidence?(size_a, size_b, lenient?) or
      no_evidence?(hash_a, hash_b, size_a, size_b)
  end

  defp same_hash?(hash, hash) when hash != nil, do: true
  defp same_hash?(_a, _b), do: false

  # Two known sizes must be close. With one unknown, only the lenient rule accepts.
  defp size_evidence?(a, b, _lenient?) when is_integer(a) and is_integer(b),
    do: sizes_close?(a, b)

  defp size_evidence?(_a, _b, lenient?), do: lenient?

  # Neither side says anything about hash or size.
  defp no_evidence?(nil, nil, nil, nil), do: true
  defp no_evidence?(_hash_a, _hash_b, _size_a, _size_b), do: false

  defp sizes_close?(a, b), do: abs(a - b) <= max(a, b) * @size_tolerance

  defp hash(%Release{info_hash: h}) when is_binary(h) and h != "", do: String.downcase(h)
  defp hash(_), do: nil

  defp size(%Release{size: s}) when is_integer(s) and s > 0, do: s
  defp size(_), do: nil

  @doc false
  def normalize_title(nil), do: ""

  def normalize_title(title) do
    title
    |> String.downcase()
    |> String.replace(~r/\s+/u, " ")
    |> String.replace(~r/\A[^\p{L}\p{N}]+|[^\p{L}\p{N}]+\z/u, "")
  end
end
