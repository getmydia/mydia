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
  """

  alias Mydia.Indexers.Cardigann.Bench.Release

  @size_tolerance 0.01

  @spec same?(Release.t(), Release.t()) :: boolean()
  def same?(%Release{} = a, %Release{} = b) do
    normalize_title(a.title) == normalize_title(b.title) and evidence_matches?(a, b)
  end

  @doc """
  Jaccard similarity of two release lists under greedy one-to-one matching:
  `matched / (|a| + |b| - matched)`. Two empty lists are identical (1.0).
  """
  @spec jaccard([Release.t()], [Release.t()]) :: float()
  def jaccard([], []), do: 1.0

  def jaccard(a, b) do
    %{matched: matched, only_left: left, only_right: right} = pair(a, b)
    union = matched + length(left) + length(right)
    matched / union
  end

  @doc "The releases present on only one side after one-to-one matching."
  @spec diff([Release.t()], [Release.t()]) :: %{
          only_left: [Release.t()],
          only_right: [Release.t()]
        }
  def diff(a, b) do
    %{only_left: left, only_right: right} = pair(a, b)
    %{only_left: left, only_right: right}
  end

  defp pair(left, right) do
    {pool, matched, unmatched_left} =
      Enum.reduce(left, {right, 0, []}, fn release, {pool, count, lonely} ->
        case take_match(pool, release) do
          {:ok, rest} -> {rest, count + 1, lonely}
          :error -> {pool, count, [release | lonely]}
        end
      end)

    %{matched: matched, only_left: Enum.reverse(unmatched_left), only_right: pool}
  end

  defp take_match(pool, release) do
    case Enum.find_index(pool, &same?(release, &1)) do
      nil -> :error
      index -> {:ok, List.delete_at(pool, index)}
    end
  end

  defp evidence_matches?(a, b) do
    hash_a = hash(a)
    hash_b = hash(b)
    size_a = size(a)
    size_b = size(b)

    cond do
      hash_a != nil and hash_a == hash_b -> true
      size_a != nil and size_b != nil and sizes_close?(size_a, size_b) -> true
      hash_a == nil and hash_b == nil and size_a == nil and size_b == nil -> true
      true -> false
    end
  end

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
