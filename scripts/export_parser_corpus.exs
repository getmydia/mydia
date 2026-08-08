# Exports the harvested Radarr and Sonarr corpora as a JSON oracle for the
# Rust parser in server/crates/library.
#
# Run with: mix run scripts/export_parser_corpus.exs
#
# Only cases asserting title, year, season, episode or episodes are exported.
# Everything else in the corpus (proper, edition, release_group, language,
# hash, version, reality, absolute_episode) asserts behaviour Mydia Server's
# parser deliberately does not have.

alias Mydia.Library.ReleaseParser
alias Mydia.Library.Structs.ParsedFileInfo

targets = [:title, :year, :season, :episode, :episodes]

load = fn path ->
  {corpus, _binding} = Code.eval_file(path)
  corpus.cases
end

normalize = fn
  nil -> nil
  value when is_binary(value) -> value |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "")
end

expected_for = fn expected ->
  base = Map.take(expected, targets)

  case Map.get(base, :episodes) do
    [first | _] = list ->
      base
      |> Map.delete(:episodes)
      |> Map.put(:episode, first)
      |> Map.put(:episode_end, List.last(list))

    _ ->
      Map.delete(base, :episodes)
  end
end

passes? = fn parsed, expected ->
  Enum.all?(expected, fn
    {:title, want} -> normalize.(parsed.title) == normalize.(want)
    {:year, want} -> parsed.year == want
    {:season, want} -> parsed.season == want
    {:episode, want} -> ParsedFileInfo.primary_episode(parsed) == want
    {:episode_end, _want} -> true
  end)
end

cases =
  ["test/fixtures/release_parser/radarr_corpus.exs", "test/fixtures/release_parser/sonarr_corpus.exs"]
  |> Enum.flat_map(load)
  |> Enum.filter(fn c -> Enum.any?(Map.keys(c.expected), &(&1 in targets)) end)
  |> Enum.map(fn c ->
    expected = expected_for.(c.expected)
    parsed = ReleaseParser.parse(c.input)

    %{
      input: c.input,
      expected: expected,
      elixir_passes: passes?.(parsed, expected)
    }
  end)
  |> Enum.uniq_by(& &1.input)
  |> Enum.sort_by(& &1.input)

out = "server/crates/library/tests/fixtures/parser_corpus.json"
File.mkdir_p!(Path.dirname(out))
File.write!(out, Jason.encode_to_iodata!(cases, pretty: true))

elixir_passing = Enum.count(cases, & &1.elixir_passes)

IO.puts("wrote #{length(cases)} cases to #{out}")
IO.puts("the Elixir parser passes #{elixir_passing} of them")
