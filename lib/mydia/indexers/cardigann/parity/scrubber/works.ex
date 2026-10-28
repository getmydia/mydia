defmodule Mydia.Indexers.Cardigann.Parity.Scrubber.Works do
  @moduledoc """
  Learns the real names to scrub from release titles: the work before a
  title's first marker and every segment of it that reads as a name. The
  renaming itself is `Mydia.Indexers.Cardigann.Parity.Scrubber.Names`.
  """

  @min_work_length 3
  @marker ~r/\A(?:(?:19|20)\d\d|S\d{1,2}E\d{1,3}|S\d{1,2}|\d{3,4}p|WEB|WEB-DL|WEBRip|BluRay|HDTV|DVDRip)\z/i
  @token ~r/[^ ._-]+/
  @first_token ~r/\A[^ ._-]+[ ._-]*/
  @brackets ~r/\A[(\[{]+|[)\]}]+\z/
  @slug_words ~r/[^\p{L}\p{N}]+/u
  @letters ~r/\p{L}+/u
  @letters_or_digits ~r/[\p{L}\p{N}]+/u
  @segment_split ~r/[\[\]【】()（）{}「」\/\\|,，~★]| - | \+ /u
  @min_segment 5
  @min_segment_cjk 3
  @min_pair 8
  @release_words ~w(aac amzn atmos audio avc avi baha batch bdrip bili cht chs complete ddp
                    dual dub dubbed edition eng english episode flac hdr hevc jpn mkv movie
                    multi opus part proper raw raws remastered repack sdr season sub subbed
                    subfrench subs tags uhd uhdbdrip uncensored viutv vol vostfr web webdl webrip
                    incl keygen patch crack activator portable keymaker serial license
                    final build beta x64 x86
                    multisub multisubs dualaudio arabic cantonese chinese french german
                    indonesian italian japanese korean mandarin portuguese russian spanish
                    thai vietnamese)

  @doc """
  Splits a release title into its work name and the rest, at the first token
  (separated by space, `.`, `_` or `-`, brackets ignored) that is a year, an
  episode or season marker, a resolution or a source. A title with no such
  token is all work.
  """
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

  # A work stops before an opening bracket that starts a date or number, so
  # "Name (21.04.2031)" keeps its date intact when the name is renamed.
  defp cut(title, at) do
    work =
      title
      |> binary_part(0, at)
      |> String.replace(~r/[ ._-]+\z/, "")
      |> String.replace(~r/\s*\(\s*[\d.\/-]*\z/, "")
      |> String.trim()

    {work, binary_part(title, at, byte_size(title) - at)}
  end

  @doc """
  The distinct work names of `titles` that are long enough to rename safely,
  longest first. Shorter ones ("Up") would match inside markup.

  Besides the work before a title's first marker, every segment of the title
  that reads as a name counts: segments are cut at brackets, slashes, bars,
  commas, `~` and a spaced dash. Fansub titles put the name inside brackets
  (`[Group][Some Name][04][1080p]`) and list alternate names after a slash or
  in a trailing `(VOSTFR, Other Name)`, and a composed title joins the name to
  a platform with ` - `; each of those is a real name too. So is an episode
  title after a marker (`S01E04 The Long Way Home 1080p`).
  """
  @spec works([String.t()]) :: [String.t()]
  def works(titles) do
    titles
    |> Enum.flat_map(&[work(&1) | segment_works(&1)])
    |> Enum.filter(&renamable?/1)
    |> Enum.uniq()
    |> Enum.sort_by(&{-byte_size(&1), &1})
  end

  defp segment_works(title) do
    for segment <- Regex.split(@segment_split, title),
        {run, n} <- segment |> runs() |> Enum.map(&String.trim/1) |> Enum.with_index(),
        variant <- Enum.uniq([run, without_numbered_edges(run) | latin_chunks(run)]),
        name?(variant),
        n == 0 or episode_title?(variant),
        do: variant
  end

  # A name written in two scripts ("Name Two 漢字名") is often shown with the
  # Latin part alone (a slug, an alt text), so each Latin chunk of a run that
  # also holds other letters is learned on its own.
  defp latin_chunks(run) do
    if run =~ ~r/[^\x00-\x7F]/u do
      for chunk <- Regex.scan(~r/[A-Za-z0-9][\x20-\x7E’]*[A-Za-z0-9]/u, run),
          chunk = hd(chunk) |> String.trim() |> without_numbered_edges(),
          do: chunk
    else
      []
    end
  end

  # A title filter may rewrite a numbered prefix the page still shows in full
  # ("Выпуск 695. Name" becomes "E695. Name"), so the run without its leading
  # and trailing numbered tokens is learned as well. A software title's version
  # and crack tags ("Name 12.1.0 Incl Keygen") go
  # the same way, so the name alone is learned.
  defp without_numbered_edges(run) do
    tokens = String.split(run)

    tokens
    |> Enum.drop_while(&edge_token?/1)
    |> Enum.reverse()
    |> Enum.drop_while(&edge_token?/1)
    |> Enum.reverse()
    |> Enum.join(" ")
    |> String.trim()
  end

  # The text before a segment's first marker, then the text between each pair
  # of markers after it.
  defp runs(segment) do
    case split_title(segment) do
      {work, ""} -> [work]
      {work, rest} -> [work | rest |> String.replace(@first_token, "") |> runs()]
    end
  end

  # Between two markers sits either an episode title or more tags
  # ("x264-Group"); two words that are not release vocabulary tell them apart.
  defp episode_title?(run) do
    words =
      @letters
      |> Regex.scan(String.downcase(run))
      |> List.flatten()
      |> Enum.reject(&release_word?/1)

    length(words) >= 2 or run =~ ~r/[^\x00-\x7F]/u
  end

  # A segment names something when it is long enough not to hit unrelated text
  # and has a word that is not release vocabulary ("1080p", "WEB-DL", "Dual
  # Audio", "CHT"). Renaming a tag would be harmless, but a short one would be
  # found inside unrelated words by the leak check and fail every seed.
  defp name?(work) do
    reduced = work |> String.downcase() |> String.replace(@slug_words, "")
    min = if reduced =~ ~r/[^\x00-\x7F]/u, do: @min_segment_cjk, else: @min_segment

    String.length(reduced) >= min and
      @letters
      |> Regex.scan(String.downcase(work))
      |> List.flatten()
      |> Enum.any?(&(not release_word?(&1)))
  end

  defp edge_token?(token) do
    token =~ ~r/\d/u or
      token |> String.downcase() |> String.replace(~r/[^\p{L}]/u, "") |> release_word?()
  end

  defp release_word?(word),
    do:
      word in @release_words or Regex.match?(@marker, word) or
        (String.length(word) < 3 and word =~ ~r/\A[a-z]+\z/)

  @doc "The work name of one title."
  @spec work(String.t()) :: String.t()
  def work(title), do: title |> split_title() |> elem(0) |> String.trim()

  @doc "Whether a work is long enough to rename without hitting markup."
  @spec renamable?(String.t()) :: boolean()
  def renamable?(work), do: String.length(work) >= @min_work_length

  @doc """
  Adjacent pairs of a work's words that are not release vocabulary or bare
  numbers, each reduced to lowercase letters and digits. A work renamed only in
  part ("Old Kiln" taken out of "Old Kiln 2: The Return") leaves such a pair
  behind, which the whole-work search cannot see.
  """
  @spec distinctive_pairs(String.t()) :: [String.t()]
  def distinctive_pairs(work) do
    words =
      @letters_or_digits
      |> Regex.scan(String.downcase(work))
      |> List.flatten()
      |> Enum.reject(&(release_word?(&1) or &1 =~ ~r/\A\d+\z/u))

    for [a, b] <- Enum.chunk_every(words, 2, 1, :discard),
        pair = a <> b,
        String.length(pair) >= @min_pair,
        uniq: true,
        do: pair
  end
end
