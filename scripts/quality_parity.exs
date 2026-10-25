# Field-by-field comparison of Mydia.Library.ReleaseParser against
# Mydia.Indexers.QualityParser (issue #1205). Deleted once QualityParser
# wraps ReleaseParser.
#
#   MIX_ENV=test ./dev mix run --no-start scripts/quality_parity.exs
#   MIX_ENV=test ./dev mix run --no-start scripts/quality_parity.exs --titles /path/titles.txt --examples 20

defmodule QualityParity do
  alias Mydia.Indexers.QualityParser
  alias Mydia.Library.ReleaseParser

  @fields [:resolution, :source, :codec, :audio, :hdr_format, :dolby_vision, :proper, :repack]

  def fields, do: @fields

  def compare(title) do
    rp = ReleaseParser.parse(title).quality
    qp = QualityParser.parse(title)
    Map.new(@fields, fn f -> {f, judge(f, Map.get(rp, f), Map.get(qp, f))} end)
  end

  # :rp_worse  = QualityParser found something ReleaseParser did not.
  # :rp_better = ReleaseParser found something QualityParser did not.
  # :differ    = both found a value and they disagree after normalization.
  defp judge(_f, same, same), do: :same
  defp judge(_f, rp, qp) when rp in [nil, false] and qp not in [nil, false], do: :rp_worse
  defp judge(_f, rp, qp) when qp in [nil, false] and rp not in [nil, false], do: :rp_better

  defp judge(:audio, rp, qp) when is_binary(rp) and is_binary(qp) do
    # "DD+ 5.1" vs "DD+": same codec, ReleaseParser carries more.
    if String.starts_with?(rp, qp <> " "), do: :rp_better, else: :differ
  end

  defp judge(_f, _rp, _qp), do: :differ
end

{opts, _, _} = OptionParser.parse(System.argv(), strict: [titles: :string, examples: :integer])

titles =
  case opts[:titles] do
    nil ->
      for file <- ~w(sonarr_corpus.exs radarr_corpus.exs),
          {%{cases: cases}, _} = Code.eval_file(Path.join("test/fixtures/release_parser", file)),
          %{input: input} <- cases,
          uniq: true,
          do: input

    path ->
      path |> File.read!() |> String.split("\n", trim: true) |> Enum.uniq()
  end

Logger.configure(level: :warning)
results = Enum.map(titles, &{&1, QualityParity.compare(&1)})
max_examples = opts[:examples] || 5

IO.puts("#{length(titles)} titles\n")

for field <- QualityParity.fields() do
  verdicts = Enum.map(results, fn {t, r} -> {t, r[field]} end)
  count = fn v -> Enum.count(verdicts, &(elem(&1, 1) == v)) end
  IO.puts("#{field}: differ=#{count.(:differ)} rp_better=#{count.(:rp_better)} rp_worse=#{count.(:rp_worse)}")

  for {t, :rp_worse} <- Enum.take(Enum.filter(verdicts, &(elem(&1, 1) == :rp_worse)), max_examples) do
    IO.puts("    worse: #{t}")
  end

  for {t, :differ} <- Enum.take(Enum.filter(verdicts, &(elem(&1, 1) == :differ)), max_examples) do
    IO.puts("    differ: #{t}")
  end
end
