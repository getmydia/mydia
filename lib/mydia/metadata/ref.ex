defmodule Mydia.Metadata.Ref do
  @moduledoc """
  A provider-tagged media id: `{:tmdb, 63639}` or `{:tvdb, 280619}`.

  A bare integer id is ambiguous. TMDB and TVDB number their catalogs
  independently, so 280619 names a series on TVDB and nothing at all on
  TMDB. Every function that fetches by id takes one of these instead of an
  integer, which is what stops a caller from sending an id to the wrong
  provider.

  The type is a tagged tuple rather than a struct so call sites dispatch in the
  function head:

      def fetch_by_ref(config, {:tvdb, id}, opts), do: ...
      def fetch_by_ref(config, {:tmdb, id}, opts), do: ...

  A provider added later produces a `FunctionClauseError` at the call site
  rather than silently taking an else branch.
  """

  alias Mydia.Metadata.Structs.SearchResult

  @type provider :: :tmdb | :tvdb
  @type t :: {provider(), pos_integer()}

  @doc """
  Parses the wire format used by `phx-value-ref`.

  Total by construction: one clause per allowlisted tag plus a catch-all, so a
  hostile param cannot reach `String.to_atom/1` and grow the atom table.

      iex> Mydia.Metadata.Ref.parse("tvdb:280619")
      {:ok, {:tvdb, 280619}}

      iex> Mydia.Metadata.Ref.parse("imdb:tt3230854")
      :error
  """
  @spec parse(String.t()) :: {:ok, t()} | :error
  def parse("tmdb:" <> id), do: tagged(:tmdb, id)
  def parse("tvdb:" <> id), do: tagged(:tvdb, id)
  def parse(_other), do: :error

  defp tagged(provider, id) do
    case Integer.parse(id) do
      {n, ""} when n > 0 -> {:ok, {provider, n}}
      _ -> :error
    end
  end

  @doc """
  Renders a ref for a `phx-value-ref` attribute.

      iex> Mydia.Metadata.Ref.to_param({:tmdb, 63639})
      "tmdb:63639"
  """
  @spec to_param(t()) :: String.t()
  def to_param({provider, id}) when provider in [:tmdb, :tvdb] and is_integer(id) and id > 0,
    do: "#{provider}:#{id}"

  @doc "The provider that owns this id."
  @spec provider(t()) :: provider()
  def provider({provider, _id}), do: provider

  @doc "The id itself, as an integer."
  @spec id(t()) :: pos_integer()
  def id({_provider, id}), do: id

  @doc """
  Builds a ref from a search result, which already knows its own provenance.

  Raises when `provider_id` is not an integer. A `SearchResult` is built by our
  own provider parsing, so a non-integer id there is a parsing bug worth
  surfacing rather than a user input worth tolerating.

  Deliberately locked to the real struct rather than any map carrying
  `provider_id`. This function's whole point is "the item already knows its
  own provenance, so do not guess" -- `SearchResult` enforces `:provider` at
  construction (`@enforce_keys`), so a real one can never lack it. A bare map
  can, and defaulting a missing `:provider` to `:tmdb` here would be the exact
  silent-guess defect this refactor exists to delete, sitting in the one
  place built to prevent it. Callers that only have a plain map (a franchise
  entry, a hand-built test fixture) must build a real `%SearchResult{}` with
  the provider they actually mean, not lean on a default here.
  """
  @spec from_search_result(SearchResult.t()) :: t()
  def from_search_result(%SearchResult{provider: provider, provider_id: provider_id}) do
    {normalize_provider(provider), String.to_integer(to_string(provider_id))}
  end

  # `:metadata_relay` names the config type that served a response, not the
  # provider that owns the id. Producers emit `:tmdb` as of this change, but
  # metadata blobs stored before it still read back as `:metadata_relay`, so
  # this stays as read tolerance. It is not a default for new writes.
  defp normalize_provider(:tvdb), do: :tvdb
  defp normalize_provider(_tmdb_or_legacy_relay), do: :tmdb

  @doc false
  # Reproduces the routing `Provider.Relay` used before refs existed: TV goes
  # to TVDB unless `provider: :tmdb` says otherwise. The one copy of this rule
  # lives here so the old `fetch_by_id`/`fetch_images`/`fetch_season` shims in
  # every provider can call it without duplicating the condition. Deleted in
  # the final task of this plan, along with the shims that call it.
  @spec legacy_from_opts(String.t() | integer(), keyword()) :: t()
  def legacy_from_opts(provider_id, opts) do
    media_type = Keyword.get(opts, :media_type, :movie)
    provider = Keyword.get(opts, :provider)

    tag =
      if provider == :tvdb or (media_type == :tv_show and provider != :tmdb),
        do: :tvdb,
        else: :tmdb

    {tag, String.to_integer(to_string(provider_id))}
  end
end
