defmodule Mydia.Indexers.Cardigann.Parity.DiffTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.Cardigann.Parity.{Diff, RequestKey}
  alias Mydia.Indexers.SearchResult

  @hash_a "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  @hash_b "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

  defp result(title, hash, attrs \\ []) do
    base = [
      title: title,
      size: 1000,
      seeders: 5,
      leechers: 2,
      download_url: "magnet:?xt=urn:btih:#{hash}&dn=#{URI.encode_www_form(title)}",
      indexer: "x",
      category: 2000,
      metadata: %{info_hash: hash}
    ]

    SearchResult.new(Keyword.merge(base, attrs))
  end

  defp run(n, w, misses \\ []),
    do: Diff.compare("lantern", :rss, {:ok, n}, {:ok, w}, misses)

  test "identical lists agree on every pair" do
    list = [result("Lantern Harbor", @hash_a), result("Quiet Orchard", @hash_b)]
    assert %{divergences: [], paired: 2, agreeing: 2} = run(list, list)
  end

  test "one side erroring is a single outcome divergence" do
    err = {:error, %{type: :timeout}}
    out = Diff.compare("lantern", :rss, err, {:ok, [result("Lantern Harbor", @hash_a)]}, [])
    assert [%{kind: :outcome, field: nil}] = out.divergences
    assert out.paired == 0
  end

  test "both erroring with different types diverges, same type does not" do
    a = {:error, %{type: :timeout}}
    b = {:error, %{type: :parse_error}}
    assert [%{kind: :outcome}] = Diff.compare("d", :rss, a, b, []).divergences
    assert [] = Diff.compare("d", :rss, a, a, []).divergences
  end

  test "misses become one request divergence carrying them" do
    miss = RequestKey.new(:get, "https://example.test/a?b=1", nil)
    list = [result("Lantern Harbor", @hash_a)]

    assert %{divergences: [%{kind: :request, field: nil, native: [^miss]}]} =
             run(list, list, [miss])
  end

  test "count mismatch still diffs the pairs that exist" do
    a = result("Lantern Harbor", @hash_a)
    b = result("Quiet Orchard", @hash_b)
    out = run([a, b], [%{a | seeders: 9}])

    assert Enum.any?(out.divergences, &(&1.kind == :count and &1.native == 2 and &1.wasm == 1))
    assert Enum.any?(out.divergences, &(&1.kind == :field and &1.field == :seeders))
    assert out.paired == 1
    assert out.agreeing == 0
  end

  test "pairing by info hash survives reordering" do
    a = result("Lantern Harbor", @hash_a)
    b = result("Quiet Orchard", @hash_b)
    assert %{divergences: [], paired: 2, agreeing: 2} = run([a, b], [b, a])
  end

  test "two rows sharing a hash pair by download url, whatever their order" do
    a = result("Lantern Harbor", @hash_a, download_url: "https://t.test/dl?id=1")
    b = result("Lantern Harbor Extras", @hash_a, download_url: "https://t.test/dl?id=2")
    assert %{divergences: [], paired: 2, agreeing: 2} = run([a, b], [b, a])
  end

  test "pairing falls back to download url, then position" do
    a = result("Lantern Harbor", nil, download_url: "https://t.test/dl?id=1&k=2", metadata: nil)
    b = result("Quiet Orchard", nil, download_url: "https://t.test/dl?id=2", metadata: nil)
    a2 = %{a | download_url: "https://T.test/dl?k=2&id=1"}
    assert %{divergences: [], agreeing: 2} = run([a, b], [b, a2])
  end

  test "published_at within 60 seconds is equal, beyond is a field divergence" do
    t = ~U[2026-01-01 00:00:00Z]
    a = result("Lantern Harbor", @hash_a, published_at: t)

    assert %{divergences: []} = run([a], [%{a | published_at: DateTime.add(t, 30)}])

    assert %{divergences: [%{kind: :field, field: :published_at}]} =
             run([a], [%{a | published_at: DateTime.add(t, 90)}])
  end

  test "published_at nil on one side only differs" do
    a = result("Lantern Harbor", @hash_a, published_at: ~U[2026-01-01 00:00:00Z])
    assert [%{field: :published_at}] = run([a], [%{a | published_at: nil}]).divergences
  end

  test "magnets that differ only in ws diverge" do
    base = "magnet:?xt=urn:btih:#{@hash_a}&dn=Lantern%20Harbor"
    a = result("Lantern Harbor", @hash_a, download_url: base <> "&ws=https%3A%2F%2Fa.test%2Fx")
    b = %{a | download_url: base <> "&ws=https%3A%2F%2Fb.test%2Fx"}

    assert [%{field: :download_url}] = run([a], [b]).divergences
  end

  test "magnet trackers in a different order are equal" do
    base = "magnet:?xt=urn:btih:#{@hash_a}&dn=Lantern%20Harbor"

    a =
      result("Lantern Harbor", @hash_a,
        download_url: base <> "&tr=udp%3A%2F%2Fa.test&tr=udp%3A%2F%2Fb.test"
      )

    b = %{
      a
      | download_url:
          "magnet:?xt=urn:btih:#{String.upcase(@hash_a)}&dn=Lantern+Harbor&tr=udp%3A%2F%2Fb.test&tr=udp%3A%2F%2Fa.test"
    }

    assert %{divergences: []} = run([a], [b])
  end

  test "magnets differing only in tr are equal, as download_url and as guid" do
    base = "magnet:?xt=urn:btih:#{@hash_a}&dn=Lantern%20Harbor"
    upper = "magnet:?xt=urn:btih:#{String.upcase(@hash_a)}&dn=Lantern%20Harbor"

    a =
      result("Lantern Harbor", @hash_a,
        download_url: base <> "&tr=udp%3A%2F%2Fa.test",
        guid: base <> "&tr=udp%3A%2F%2Fa.test"
      )

    b = %{
      a
      | download_url: upper <> "&tr=udp%3A%2F%2Fb.test",
        guid: upper <> "&tr=udp%3A%2F%2Fc.test&tr=udp%3A%2F%2Fd.test"
    }

    assert %{divergences: []} = run([a], [b])
  end

  test "a guid magnet differing in dn still diverges" do
    a = result("Lantern Harbor", @hash_a, guid: "magnet:?xt=urn:btih:#{@hash_a}&dn=one")
    b = %{a | guid: "magnet:?xt=urn:btih:#{@hash_a}&dn=two"}
    assert [%{field: :guid}] = run([a], [b]).divergences
  end

  test "a size difference is a field divergence with both values" do
    a = result("Lantern Harbor", @hash_a, size: 1234)

    assert [%{kind: :field, field: :size, native: 1234, wasm: 1200}] =
             run([a], [%{a | size: 1200}]).divergences
  end

  test "metadata fields are compared, missing keys are nil" do
    a =
      result("Lantern Harbor", @hash_a,
        metadata: %{info_hash: @hash_a, download_volume_factor: 0.0}
      )

    b = %{a | metadata: %{info_hash: @hash_a}}

    assert [%{field: :download_volume_factor, native: +0.0, wasm: nil}] =
             run([a], [b]).divergences
  end

  test "a malformed magnet does not crash the diff" do
    a = result("Lantern Harbor", @hash_a, download_url: "magnet:?xt=urn:btih:#{@hash_a}&dn=%zz")
    assert %{divergences: []} = run([a], [a])

    assert [%{field: :download_url}] =
             run([a], [%{a | download_url: "magnet:?dn=%zz"}]).divergences
  end

  test "magnets pair by their btih hash even when dn and tr differ and order is swapped" do
    mk = fn title, hash, dn, trs ->
      result(title, hash,
        metadata: nil,
        download_url: "magnet:?xt=URN:BTIH:#{hash}&dn=#{dn}" <> Enum.map_join(trs, &"&tr=#{&1}")
      )
    end

    a = mk.("Lantern Harbor", @hash_a, "alpha", ["x.test"])
    b = mk.("Quiet Orchard", @hash_b, "beta", ["x.test"])
    a2 = mk.("Lantern Harbor", String.upcase(@hash_a), "alpha-2", ["y.test"])
    b2 = mk.("Quiet Orchard", @hash_b, "beta-2", ["y.test"])

    out = run([a, b], [b2, a2])

    assert out.paired == 2
    assert out.agreeing == 0
    assert [%{kind: :field, field: :download_url}] = out.divergences
  end

  test "a magnet paired with a non-magnet reports only the url difference" do
    a = result("Lantern Harbor", @hash_a, metadata: nil)
    b = %{a | download_url: "https://t.test/dl?id=1"}
    assert [%{kind: :field, field: :download_url}] = run([a], [b]).divergences
  end
end
