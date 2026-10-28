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
  """

  alias Mydia.Indexers.Cardigann.Charset
  alias Mydia.Indexers.Cardigann.Parity.Fictional

  @min_work_length 3
  @separators ~r/[ ._-]/
  @marker ~r/\A(?:(?:19|20)\d\d|S\d{1,2}E\d{1,3}|S\d{1,2}|\d{3,4}p|WEB|WEB-DL|WEBRip|BluRay|HDTV|DVDRip)\z/i
  @token ~r/[^ ._-]+/
  @brackets ~r/\A[(\[{]+|[)\]}]+\z/
  @slug_words ~r/[^\p{L}\p{N}]+/u

  @typedoc "Folded forms mapped to their replacements, and the compiled search pattern."
  @type matcher :: {%{binary() => binary()}, :binary.cp() | nil}

  @doc "See `Mydia.Indexers.Cardigann.Parity.Scrubber.split_title/1`."
  @spec split_title(String.t()) :: {String.t(), String.t()}
  def split_title(title) do
    tokens =
      @token
      |> Regex.scan(title, return: :index)
      |> Enum.map(fn [{start, len}] ->
        {start, title |> binary_part(start, len) |> String.replace(@brackets, "")}
      end)

    markers = for {start, token} <- tokens, Regex.match?(@marker, token), do: {start, token}

    case {tokens, markers} do
      {_, []} ->
        {title, ""}

      # A title that opens with a number ("1984 2031 1080p") names its work with
      # it, so the cut moves to the next marker.
      {[{first, _} | _], [{first, token}, {next, _} | _]} ->
        if Regex.match?(~r/\A\d+\z/, token), do: cut(title, next), else: cut(title, first)

      {[{first, _} | _], [{first, token}]} ->
        if Regex.match?(~r/\A\d+\z/, token), do: {String.trim(title), ""}, else: cut(title, first)

      {_, [{at, _} | _]} ->
        cut(title, at)
    end
  end

  defp cut(title, at) do
    work = title |> binary_part(0, at) |> String.replace(~r/[ ._-]+\z/, "") |> String.trim()
    {work, binary_part(title, at, byte_size(title) - at)}
  end

  @doc """
  The distinct work names of `titles` that are long enough to rename safely,
  longest first. Shorter ones ("Up") would match inside markup.
  """
  @spec works([String.t()]) :: [String.t()]
  def works(titles) do
    titles
    |> Enum.map(&work/1)
    |> Enum.filter(&renamable?/1)
    |> Enum.uniq()
    |> Enum.sort_by(&{-byte_size(&1), &1})
  end

  @doc "The work name of one title."
  @spec work(String.t()) :: String.t()
  def work(title), do: title |> split_title() |> elem(0) |> String.trim()

  @doc "Whether a work is long enough to rename without hitting markup."
  @spec renamable?(String.t()) :: boolean()
  def renamable?(work), do: String.length(work) >= @min_work_length

  @spec matcher([String.t()], String.t() | nil) :: matcher()
  def matcher(works, encoding) do
    # Earlier entries win when two works share a form, hence the reverse.
    table =
      works
      |> Enum.flat_map(&forms(&1, encoding))
      |> Enum.map(fn {form, fake} -> {fold(form), fake} end)
      |> Enum.reject(fn {form, _} -> form == "" end)
      |> Enum.reverse()
      |> Map.new()

    pattern = if table == %{}, do: nil, else: :binary.compile_pattern(Map.keys(table))
    {table, pattern}
  end

  @doc "Every folded form of `work`, for searching folded text."
  @spec needles(String.t(), String.t() | nil) :: [binary()]
  def needles(work, encoding), do: [work] |> matcher(encoding) |> elem(0) |> Map.keys()

  @doc """
  Replaces every form in `bin`. :binary.matches/2 scans left to right and, where
  several forms start at the same byte, takes the longest, so "Old Mellow Kiln"
  beats "Mellow Kiln". It runs on the folded text, whose byte offsets match the
  original's.
  """
  @spec replace(binary() | nil, matcher()) :: binary() | nil
  def replace(nil, _matcher), do: nil
  def replace(bin, {_table, nil}), do: bin

  def replace(bin, {table, pattern}) do
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

    sep =
      case Regex.run(@separators, work) do
        [s] -> s
        nil -> " "
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
