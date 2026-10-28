defmodule Mydia.Indexers.Cardigann.Parity.Scrubber.Ids do
  @moduledoc """
  Replaces real external ids and BitTorrent info hashes with invented ones.

  An IMDb id or an info hash names a real release as surely as its title does.
  Both engines only echo these values, so replacing every occurrence of one with
  the same stand-in keeps parity intact:

  - IMDb ids (`tt` and 7 to 9 digits) become `tt2` and 8 digits from a hash
    of the original (see `standin_imdb/1` for why that range).
  - Info hashes, 40 hex characters anywhere (bare, in magnets, in download
    URLs) or 32 base32 characters after `btih:`, become characters from a hash
    of the original, keeping its case.
  - TMDB, TVDB, TVMaze, AniList, MAL, TVRage and Douban ids are only recognised
    in a Torznab `<torznab:attr>` or a JSON key named for them (a bare number is
    a size as often as an id) and become `20` and 8 digits from a hash (see
    `standin_digits/1`).

  Stand-ins are deterministic, so re-seeding a capture writes the same fixture.
  """

  alias Mydia.Indexers.Cardigann.Parity.Scrubber.Names

  # A hash may follow a percent-escape (`btih%3A<hash>`), whose last character
  # is itself a hex digit.
  @hex ~r/(?:(?<=%[0-9A-Fa-f]{2})|(?<![0-9A-Fa-f]))[0-9A-Fa-f]{40}(?![0-9A-Fa-f])/
  @base32 ~r/(?<=btih:|btih%3A)[A-Za-z2-7]{32}(?![A-Za-z0-9])/i
  @imdb ~r/(?<![A-Za-z0-9])tt\d{7,9}(?!\d)/
  @id_names "imdb|imdbid|tmdb|tmdbid|tvdb|tvdbid|rageid|tvrageid|tvmazeid|anilistid|malid|doubanid"
  @attr Regex.compile!(
          ~S/(<torznab:attr\s+name="(?:/ <> @id_names <> ~S/)"\s+value=")(\d+)(")/,
          "i"
        )
  @json Regex.compile!(
          ~S/("(?:tmdb|tvdb|tvmaze|anilist|mal|rage|tvrage|douban)_?id"\s*:\s*"?)(\d+)/,
          "i"
        )

  @typedoc "Originals (hashes in lowercase) mapped to their stand-ins."
  @type t :: %{binary() => binary()}

  @doc "Every id and hash in `texts`, mapped to its stand-in."
  @spec collect([binary()]) :: t()
  def collect(texts) do
    for text <- texts, text != nil, reduce: %{} do
      acc ->
        acc
        |> put_all(@hex, text, fn h -> {String.downcase(h), standin_hex(h)} end)
        |> put_all(@base32, text, fn h -> {String.downcase(h), standin_base32(h)} end)
        |> put_all(@imdb, text, fn id -> {id, standin_imdb(id)} end)
        |> put_numeric(@attr, text)
        |> put_numeric(@json, text)
    end
  end

  defp put_all(acc, regex, text, pair) do
    regex |> Regex.scan(text) |> List.flatten() |> Enum.reduce(acc, &apply_pair(&2, pair.(&1)))
  end

  defp put_numeric(acc, regex, text) do
    for [_, _prefix, digits | _] <- Regex.scan(regex, text), reduce: acc do
      acc -> apply_pair(acc, {digits, standin_digits(digits)})
    end
  end

  defp apply_pair(acc, {original, standin}), do: Map.put_new(acc, original, standin)

  @doc "`text` with every id and hash in `ids` replaced by its stand-in."
  @spec replace(binary() | nil, t()) :: binary() | nil
  def replace(nil, _ids), do: nil

  def replace(text, ids) do
    text
    |> then(&Regex.replace(@hex, &1, fn h -> cased(h, Map.get(ids, String.downcase(h))) end))
    |> then(&Regex.replace(@base32, &1, fn h -> cased(h, Map.get(ids, String.downcase(h))) end))
    |> then(&Regex.replace(@imdb, &1, fn id -> Map.get(ids, id, id) end))
    |> then(&Regex.replace(@attr, &1, fn _, a, d, b -> a <> Map.get(ids, d, d) <> b end))
    |> then(&Regex.replace(@json, &1, fn _, a, d -> a <> Map.get(ids, d, d) end))
  end

  @doc """
  What the scrubbed capture should yield for a value the original yielded: the
  stand-in of an id or hash (an integer id stays an integer), anything else as is.
  """
  @spec translate(term(), t()) :: term()
  def translate(value, ids) when is_binary(value), do: replace(value, ids)

  def translate(value, ids) when is_integer(value) do
    case Map.fetch(ids, Integer.to_string(value)) do
      {:ok, standin} -> String.to_integer(standin)
      :error -> value
    end
  end

  def translate(value, _ids), do: value

  @doc """
  Originals still in `text`: hashes and IMDb ids anywhere (ignoring ASCII case),
  numeric ids where `collect/1` would find them.
  """
  @spec leftovers(binary(), t()) :: [binary()]
  def leftovers(text, ids) do
    folded = Names.fold(text)
    found = collect([text])

    for {original, _standin} <- ids,
        if(Regex.match?(~r/\A\d+\z/, original),
          do: Map.has_key?(found, original),
          else: String.contains?(folded, String.downcase(original))
        ),
        do: original
  end

  defp cased(original, nil), do: original

  defp cased(original, standin) do
    cond do
      original == String.upcase(original) -> String.upcase(standin)
      original == String.downcase(original) -> String.downcase(standin)
      true -> standin
    end
  end

  defp standin_hex(h), do: :sha |> digest("hash", h) |> Base.encode16(case: :lower)
  defp standin_base32(h), do: :sha |> digest("btih", h) |> Base.encode32()

  # A stand-in must never be an id that exists, or the fixture would point at a
  # real title after all. IMDb has issued fewer than 100 million title ids
  # (8 digits), so `tt2` and 8 more digits (200,000,000 to 299,999,999) is far
  # past every issued one. It stays a 9-digit number because Prowlarr stores an
  # IMDb id as a 32-bit int: `tt99` and 8 digits would overflow it, the wasm
  # engine would drop the id, and the stand-in would change what it parses.
  defp standin_imdb("tt" <> digits), do: "tt2" <> digits_from("imdb", digits, 8)

  # TMDB, TVDB, TVMaze and AniList ids are in the low millions at most, so
  # 2,000,000,000 to 2,099,999,999 has never been issued, and it is still below
  # the 32-bit limit (2,147,483,647) both engines parse ids into.
  defp standin_digits(digits), do: "20" <> digits_from("id", digits, 8)

  defp digits_from(salt, original, n) do
    :sha
    |> digest(salt, original)
    |> :binary.decode_unsigned()
    |> rem(Integer.pow(10, n))
    |> Integer.to_string()
    |> String.pad_leading(n, "0")
  end

  defp digest(alg, salt, original),
    do: :crypto.hash(alg, "mydia-parity-" <> salt <> ":" <> String.downcase(original))
end
