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
    cut =
      @token
      |> Regex.scan(title, return: :index)
      |> Enum.find_value(fn [{start, len}] ->
        token = title |> binary_part(start, len) |> String.replace(@brackets, "")
        if Regex.match?(@marker, token), do: start
      end)

    case cut do
      nil ->
        {title, ""}

      at ->
        work = title |> binary_part(0, at) |> String.replace(~r/[ ._-]+\z/, "") |> String.trim()
        {work, binary_part(title, at, byte_size(title) - at)}
    end
  end

  @doc """
  The distinct work names of `titles` that are long enough to rename safely,
  longest first. Shorter ones ("Up") would match inside markup.
  """
  @spec works([String.t()]) :: [String.t()]
  def works(titles) do
    titles
    |> Enum.map(fn title -> title |> split_title() |> elem(0) |> String.trim() end)
    |> Enum.filter(&(String.length(&1) >= @min_work_length))
    |> Enum.uniq()
    |> Enum.sort_by(&{-byte_size(&1), &1})
  end

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
    slug_words = String.split(work, @slug_words, trim: true)

    base =
      [
        {work, fake},
        {escape(work), escape(fake)},
        {URI.encode_www_form(work), URI.encode_www_form(fake)},
        {percent(work), percent(fake)}
      ] ++ for(s <- ["-", ".", "_"], do: {Enum.join(slug_words, s), Enum.join(fake_words, s)})

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
