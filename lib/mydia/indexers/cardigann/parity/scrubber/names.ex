defmodule Mydia.Indexers.Cardigann.Parity.Scrubber.Names do
  @moduledoc """
  Finds the work names in release titles and replaces them, in every form a
  tracker writes them, with invented ones.

  A work is written verbatim, HTML-escaped, form-encoded (`+`), percent-encoded
  (`%20`) and as slugs joined by `-`, `.` or `_`; for a non-UTF-8 definition the
  same forms also exist as bytes in its charset. Matching ignores ASCII case,
  because trackers repeat a name in another case (a lowercase file name next to
  a capitalised category badge), and works on raw bytes so non-UTF-8 bodies can
  be searched without decoding.

  UTF-8 text then gets a second pass that finds each work as its sequence of
  words with any punctuation, whitespace, percent-escape or entity between
  them, for the spellings no fixed form anticipates.
  """

  alias Mydia.Indexers.Cardigann.Charset
  alias Mydia.Indexers.Cardigann.Parity.Fictional
  alias Mydia.Indexers.Cardigann.Parity.Scrubber.Works

  @separators ~r/[ ._-]/
  @slug_words ~r/[^\p{L}\p{N}]+/u
  @letters_or_digits ~r/[\p{L}\p{N}]+/u
  @ellipsis_end ~r/(…|\.\.\.)\s*\z/u
  @min_segment 5
  # Between two words of a work: any punctuation or whitespace, or the
  # percent-encoding or HTML entity of one, but never a tag boundary.
  @gap "(?:[^\\p{L}\\p{N}<>]|%[0-9A-Fa-f]{2}|&#?[A-Za-z0-9]+;){1,12}"
  # A work starts after a non-word character or straight after a %XX escape
  # (`%5BGroup%5D%20Name`), and ends before a non-word character.
  @word_start "(?:(?<=%[0-9A-Fa-f]{2})|(?<![\\p{L}\\p{N}]))"
  @word_end "(?![\\p{L}\\p{N}])"

  @typedoc """
  Per work, longest first: folded forms mapped to their replacements, the
  compiled search pattern and the word-sequence regexes. Then the body charset.
  """
  @type matcher ::
          {[{%{binary() => binary()}, :binary.cp() | nil, [{Regex.t(), String.t()}]}],
           String.t() | nil}

  defdelegate split_title(title), to: Works
  defdelegate works(titles), to: Works
  defdelegate work(title), to: Works
  defdelegate renamable?(work), to: Works

  @doc """
  One entry per work, longest first, each with its forms and word sequences.
  Works are replaced one at a time in that order, forms then sequences, so a
  shorter work ("Old Kiln") can never rename the start of a longer one ("Old
  Kiln 2: The Return") and leave the rest of it behind.
  """
  @spec matcher([String.t()], String.t() | nil) :: matcher()
  def matcher(works, encoding) do
    entries =
      works
      |> Enum.uniq()
      |> Enum.sort_by(&{-byte_size(&1), &1})
      |> Enum.map(fn work ->
        table = form_table(work, encoding)
        pattern = if table == %{}, do: nil, else: :binary.compile_pattern(Map.keys(table))
        {table, pattern, word_sequence(work)}
      end)

    {entries, encoding}
  end

  # Earlier forms win when two share a folded spelling, hence the reverse.
  defp form_table(work, encoding) do
    work
    |> forms(encoding)
    |> Enum.map(fn {form, fake} -> {fold(form), fake} end)
    |> Enum.reject(fn {form, _} -> form == "" end)
    |> Enum.reverse()
    |> Map.new()
  end

  # The work as its words with any gap between them, so a spelling the forms
  # above miss is still found: `A%20Returner&apos;s%20Name` mixes two
  # encodings, a title filter may have dropped a colon the page still shows.
  # A work cut short with an ellipsis ("Some Na…") ends inside a word, so its
  # last word matches as a prefix and takes the rest of that word with it.
  defp word_sequence(work) do
    tail = if String.match?(work, @ellipsis_end), do: "[\\p{L}\\p{N}]*", else: @word_end
    fake = Fictional.name(work)

    for spelling <- spellings(work),
        words = Regex.scan(@letters_or_digits, spelling),
        words != [] do
      source = @word_start <> Enum.map_join(words, @gap, &Regex.escape(hd(&1))) <> tail
      {Regex.compile!(source, "iu"), fake}
    end
  end

  # URL slugs strip accents ("Mō" becomes "Mo"), drop the letter outright
  # ("M") or turn it into a separator ("Reiāsu" becomes "Rei_su"), so those
  # spellings are searched too, while long enough to be safe. Only for a Latin
  # name with a few accented letters: dropping a CJK name's characters would
  # leave a fragment ("U-17 WORLD CUP") that renames part of another work.
  defp spellings(work) do
    if work |> String.replace(~r/[\x00-\x7F]/u, "") |> String.length() > 2,
      do: [work],
      else: latin_spellings(work)
  end

  defp latin_spellings(work) do
    stripped = work |> :unicode.characters_to_nfd_binary() |> String.replace(~r/\p{Mn}/u, "")
    ascii = String.replace(work, ~r/[^\x00-\x7F]/u, "")

    variants =
      for v <- [
            stripped,
            ascii,
            String.replace(work, ~r/[^\x00-\x7F]/u, " "),
            # Slugs spell a multiplication sign as "x" ("name-x-name").
            String.replace(work, "×", "x")
          ],
          v != work,
          v |> String.replace(@slug_words, "") |> String.length() >= @min_segment,
          # "2026年10月番" without its CJK is "2026 10", which is a date.
          v =~ ~r/[A-Za-z]{3}/,
          do: v

    Enum.uniq([work | variants])
  end

  @doc "Every folded form of `work`, for searching folded text."
  @spec needles(String.t(), String.t() | nil) :: [binary()]
  def needles(work, encoding), do: work |> form_table(encoding) |> Map.keys()

  @doc """
  Replaces every work in `bin`, longest first: its forms (`:binary.matches/2`
  on the folded text, whose byte offsets match the original's), then its word
  sequences.
  """
  @spec replace(binary() | nil, matcher()) :: binary() | nil
  def replace(nil, _matcher), do: nil

  def replace(bin, {entries, encoding}) do
    Enum.reduce(entries, bin, fn {table, pattern, sequences}, acc ->
      acc |> replace_forms(table, pattern) |> words(sequences, encoding)
    end)
  end

  @doc "Whether the word-sequence pass can read `bin` (UTF-8, or round-trips through `encoding`)."
  @spec text?(binary(), String.t() | nil) :: boolean()
  def text?(bin, encoding),
    do:
      String.valid?(bin) or
        (encoding != nil and Charset.encode(Charset.decode(bin, encoding), encoding) == bin)

  defp replace_forms(bin, _table, nil), do: bin

  defp replace_forms(bin, table, pattern) do
    folded = fold(bin)

    {parts, last} =
      folded
      |> :binary.matches(pattern)
      |> Enum.reduce({[], 0}, fn {start, len}, {acc, pos} ->
        fake = Map.fetch!(table, binary_part(folded, start, len))
        found = binary_part(bin, start, len)
        {[shaped(found, fake), binary_part(bin, pos, start - pos) | acc], start + len}
      end)

    IO.iodata_to_binary(Enum.reverse([binary_part(bin, last, byte_size(bin) - last) | parts]))
  end

  # The word-sequence pass needs text: a body in the definition's charset is
  # decoded and encoded back, and one that does not survive that round trip
  # relies on the charset forms above.
  defp words(bin, [], _encoding), do: bin

  defp words(bin, sequences, encoding) do
    cond do
      String.valid?(bin) ->
        apply_sequences(bin, sequences)

      text?(bin, encoding) ->
        bin |> Charset.decode(encoding) |> apply_sequences(sequences) |> Charset.encode(encoding)

      true ->
        bin
    end
  end

  defp apply_sequences(text, sequences) do
    Enum.reduce(sequences, text, fn {regex, fake}, acc ->
      Regex.replace(regex, acc, fn found -> shaped(found, joined(fake, found)) end)
    end)
  end

  # The replacement's words joined the way the found text joins its first two.
  # A one-word occurrence gets a one-word name (see forms/2).
  defp joined(fake, found) do
    sep =
      case Regex.run(~r/%20|\+|[ ._-]/, found) do
        [s] -> s
        nil -> ""
      end

    fake |> String.split(" ") |> Enum.join(sep)
  end

  @doc "ASCII case folding on raw bytes; byte offsets are unchanged."
  @spec fold(binary()) :: binary()
  def fold(bin), do: for(<<c <- bin>>, into: "", do: <<if(c in ?A..?Z, do: c + 32, else: c)>>)

  # An occurrence with no capital letter gets the lowercase replacement.
  defp shaped(found, fake) do
    if fold(found) == found, do: String.downcase(fake), else: fake
  end

  # `{written form, replacement}` for one work.
  defp forms(work, encoding) do
    fake_words = work |> Fictional.name() |> String.split(" ")

    # A one-word work gets a one-word name ("CopperKiln"): a space would land
    # inside URLs and slugs, where the engines' escaping differs and would show
    # up as a divergence the real page never had.
    sep =
      case Regex.run(@separators, work) do
        [s] -> s
        nil -> ""
      end

    fake = Enum.join(fake_words, sep)
    # Slugs either split at an apostrophe ("kiln-s-harbor") or drop it
    # ("kilns-harbor"); trackers do both.
    slugs =
      for text <- [work, String.replace(work, ~r/['’]/u, "")],
          words = String.split(text, @slug_words, trim: true),
          s <- ["-", ".", "_"],
          do: {Enum.join(words, s), Enum.join(fake_words, s)}

    # Phoenix writes an apostrophe as &#39;; other encoders use these.
    apostrophes =
      for spelling <- ["&#039;", "&apos;", "&#x27;"],
          do: {String.replace(escape(work), "&#39;", spelling), escape(fake)}

    base =
      [
        {work, fake},
        {escape(work), escape(fake)},
        {URI.encode_www_form(work), URI.encode_www_form(fake)},
        {percent(work), percent(fake)}
      ] ++ apostrophes ++ slugs

    # Lowercase forms only matter for non-ASCII letters, which fold/1 leaves alone.
    utf8 = base ++ Enum.map(base, fn {p, r} -> {String.downcase(p), String.downcase(r)} end)
    utf8 ++ charset_forms(work, fake, encoding, utf8)
  end

  # The same forms as bytes in the definition's charset, including the
  # percent-encodings a non-UTF-8 tracker puts in its links.
  defp charset_forms(work, fake, encoding, utf8) do
    bytes = Charset.encode(work, encoding)

    if bytes == work do
      []
    else
      lower = Charset.encode(String.downcase(work), encoding)

      Enum.map(utf8, fn {p, r} -> {Charset.encode(p, encoding), r} end) ++
        [
          {URI.encode_www_form(bytes), URI.encode_www_form(fake)},
          {percent(bytes), percent(fake)},
          {URI.encode_www_form(lower), URI.encode_www_form(String.downcase(fake))},
          {percent(lower), percent(String.downcase(fake))}
        ]
    end
  end

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  defp percent(text), do: URI.encode(text, &URI.char_unreserved?/1)
end
