# Cardigann benchmark oracle

A pinned Prowlarr (v2.6.5.5623, the same commit the wasm guest is built from)
used as ground truth when comparing Mydia's Elixir Cardigann engine against the
wasm engine. Dev tooling only; nothing here runs in tests or at app start.

## Start it

```sh
cd bench/cardigann
docker compose up -d
```

The image is pinned by tag and digest in `docker-compose.yml`. Prowlarr listens
on `127.0.0.1:9696` and keeps its state in `bench/cardigann/data/`, which is
gitignored.

## API key

Prowlarr generates a key on first start. Read it from `data/config.xml`:

```sh
grep -o '<ApiKey>[^<]*' data/config.xml | sed 's/<ApiKey>//'
```

Pass it to the client as an argument. Never commit it.

## Use the client

```elixir
alias Mydia.Indexers.Cardigann.Bench.Oracle

oracle = Oracle.new("http://127.0.0.1:9696", api_key)
{:ok, id} = Oracle.ensure_indexer(oracle, "some-definition", %{"username" => "u"})

{:ok, releases} =
  Oracle.search(oracle, id, %{
    kind: :search, term: "ubuntu", categories: [], imdb_id: nil, tmdb_id: nil,
    tvdb_id: nil, season: nil, episode: nil, limit: 100, offset: nil
  })
```

Releases come back as `Bench.Release` structs, the same shape the two Mydia
engines are mapped into, so the runner can diff them.

## Stop it

```sh
docker compose down
```
