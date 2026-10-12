defmodule Mydia.Indexers.Cardigann.Bench.CorpusTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.Cardigann.Bench.Corpus

  @files [
    %{"name" => "movie-site.yml", "download_url" => "u/movie-site.yml"},
    %{"name" => "tv-site.yml", "download_url" => "u/tv-site.yml"},
    %{"name" => "plain-site.yml", "download_url" => "u/plain-site.yml"},
    %{"name" => "priv-site.yml", "download_url" => "u/priv-site.yml"},
    %{"name" => "both-site.yml", "download_url" => "u/both-site.yml"}
  ]

  defp yaml(id, type, modes) do
    mode_lines = Enum.map_join(modes, "\n", &"    #{&1}: [q]")

    "id: #{id}\nname: #{id} name\ntype: #{type}\ncaps:\n  modes:\n#{mode_lines}\nsearch:\n  paths:\n    - path: /\n"
  end

  defp bodies do
    %{
      "u/movie-site.yml" => yaml("movie-site", "public", ["search", "movie-search"]),
      "u/tv-site.yml" => yaml("tv-site", "public", ["search", "tv-search"]),
      "u/plain-site.yml" => yaml("plain-site", "public", ["search"]),
      "u/priv-site.yml" => yaml("priv-site", "private", ["search"]),
      "u/both-site.yml" => yaml("both-site", "public", ["search", "tv-search", "movie-search"])
    }
  end

  defp opts(extra \\ []) do
    dir = Path.join(System.tmp_dir!(), "corpus-test-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    [
      cache_dir: dir,
      ref: "testref",
      list_fn: fn _ref -> {:ok, @files} end,
      fetch_fn: fn url -> {:ok, Map.fetch!(bodies(), url)} end
    ]
    |> Keyword.merge(extra)
  end

  defp by_id(defs), do: Map.new(defs, &{&1.id, &1})

  test "queries are matched to capabilities, plus the empty RSS query" do
    {:ok, defs, _meta} = Corpus.load(opts())
    defs = by_id(defs)

    assert [%{label: "movie", term: "1080p"}, %{label: "rss", term: ""}] =
             defs["movie-site"].queries

    assert [%{label: "tv", term: "S01E01"}, %{label: "rss", term: ""}] = defs["tv-site"].queries

    assert [%{label: "generic", term: "2024"}, %{label: "rss", term: ""}] =
             defs["plain-site"].queries

    assert hd(defs["both-site"].queries).label == "movie"
    assert Enum.all?(defs["movie-site"].queries, &(&1.kind == :search))
  end

  test "private definitions are skipped without credentials and reported" do
    {:ok, defs, meta} = Corpus.load(opts())
    refute "priv-site" in Enum.map(defs, & &1.id)
    assert %{id: "priv-site", reason: :no_credentials} in meta.skipped
  end

  test "private definitions are included with credentials, carrying settings" do
    creds = %{"priv-site" => %{"username" => "u", "password" => "p"}}
    {:ok, defs, _} = Corpus.load(opts(credentials: creds))
    priv = by_id(defs)["priv-site"]
    assert priv.type == "private"
    assert priv.settings == %{"username" => "u", "password" => "p"}
    assert priv.credentials?
  end

  test "limit and only apply in id order" do
    {:ok, defs, _} = Corpus.load(opts(limit: 2))
    assert Enum.map(defs, & &1.id) == ["both-site", "movie-site"]

    {:ok, defs, _} = Corpus.load(opts(only: ["tv-site", "plain-site"]))
    assert Enum.map(defs, & &1.id) == ["plain-site", "tv-site"]
  end

  test "definitions are cached under the ref and not fetched twice" do
    parent = self()
    o = opts()

    o =
      Keyword.put(o, :fetch_fn, fn url ->
        send(parent, {:fetched, url})
        {:ok, Map.fetch!(bodies(), url)}
      end)

    {:ok, _, _} = Corpus.load(o)
    assert_received {:fetched, "u/movie-site.yml"}
    flush()
    {:ok, _, _} = Corpus.load(o)
    refute_received {:fetched, _}
    assert File.exists?(Path.join([o[:cache_dir], "testref", "movie-site.yml"]))
  end

  test "a failed download is skipped and reported, not fatal" do
    o =
      Keyword.put(opts(), :fetch_fn, fn
        "u/tv-site.yml" -> {:error, :boom}
        url -> {:ok, Map.fetch!(bodies(), url)}
      end)

    {:ok, defs, meta} = Corpus.load(o)
    refute "tv-site" in Enum.map(defs, & &1.id)
    assert %{id: "tv-site", reason: {:fetch, :boom}} in meta.skipped
  end

  defp flush do
    receive do
      _ -> flush()
    after
      0 -> :ok
    end
  end
end
