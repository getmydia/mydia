defmodule MydiaWeb.MediaLive.Index.ListingParams do
  @moduledoc """
  The library listing's URL state: search, filters, sort and how many rows are
  on screen. `letter` is where an A-Z jump started the window; `shown` counts
  rows from there, and `above` the rows loaded before it by scrolling up.

  Keeping it in the URL is what lets Back from a title restore the list as it
  was. Default values are left out of the URL, so an untouched page keeps a
  bare path. Anything unrecognised parses to its default. Back restores at
  most `max_shown/0` rows.

  The sort and filters are also saved per user and page, and a visit whose URL
  sets none of them starts from the saved ones.
  """

  alias Mydia.Media.LibraryListing

  @first_page 50
  @max_shown 1000
  @default_sort "title_asc"
  @progress %{
    "missing" => :missing,
    "partial" => :partial,
    "downloading" => :downloading,
    "downloaded" => :downloaded,
    "upcoming" => :upcoming
  }
  @qualities ~w(720p 1080p 2160p)
  @remembered_keys ~w(library progress monitored quality sort)

  defstruct search: "",
            library: nil,
            progress: nil,
            monitored: nil,
            quality: nil,
            sort: @default_sort,
            letter: nil,
            shown: @first_page,
            above: 0

  @type t :: %__MODULE__{
          search: String.t(),
          library: binary() | nil,
          progress: :missing | :partial | :downloading | :downloaded | :upcoming | nil,
          monitored: boolean() | nil,
          quality: String.t() | nil,
          sort: String.t(),
          letter: String.t() | nil,
          shown: pos_integer(),
          above: non_neg_integer()
        }

  @spec first_page() :: pos_integer()
  def first_page, do: @first_page

  @spec max_shown() :: pos_integer()
  def max_shown, do: @max_shown

  @doc "Parses URL params. `library_ids` are the libraries the page offers."
  @spec parse(map(), [binary()]) :: t()
  def parse(params, library_ids) do
    %__MODULE__{
      search: if(is_binary(params["q"]), do: params["q"], else: ""),
      library: Enum.find(library_ids, &(&1 == params["library"])),
      progress: Map.get(@progress, params["progress"]),
      monitored: monitored(params["monitored"]),
      quality: if(params["quality"] in @qualities, do: params["quality"]),
      sort:
        if(params["sort"] in LibraryListing.sort_keys(),
          do: params["sort"],
          else: @default_sort
        ),
      letter: letter(params["letter"]),
      shown: shown(params["shown"]),
      above: above(params["above"])
    }
  end

  @spec to_query(t()) :: [{String.t(), String.t()}]
  def to_query(%__MODULE__{} = p) do
    [
      {"q", p.search},
      {"library", p.library},
      {"progress", p.progress && Atom.to_string(p.progress)},
      {"monitored", if(is_nil(p.monitored), do: nil, else: to_string(p.monitored))},
      {"quality", p.quality},
      {"sort", if(p.sort == @default_sort, do: nil, else: p.sort)},
      {"letter", p.letter},
      {"shown", if(p.shown == @first_page, do: nil, else: Integer.to_string(p.shown))},
      {"above", if(p.above == 0, do: nil, else: Integer.to_string(p.above))}
    ]
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
  end

  @doc "The URL keys a library page remembers between visits."
  @spec remembered_keys() :: [String.t()]
  def remembered_keys, do: @remembered_keys

  @doc """
  The sort and filters as query pairs, the part of the state a page
  remembers. Search, the jump letter and the window are not remembered.
  """
  @spec to_remembered(t()) :: %{optional(String.t()) => String.t()}
  def to_remembered(%__MODULE__{} = p) do
    p
    |> to_query()
    |> Enum.filter(fn {key, _value} -> key in @remembered_keys end)
    |> Map.new()
  end

  @doc "Whether raw URL params set any remembered key, which then wins over the saved state."
  @spec listing_in_url?(map()) :: boolean()
  def listing_in_url?(params), do: Enum.any?(@remembered_keys, &Map.has_key?(params, &1))

  @spec path(String.t(), t()) :: String.t()
  def path(base, %__MODULE__{} = p) do
    case to_query(p) do
      [] -> base
      query -> base <> "?" <> URI.encode_query(query)
    end
  end

  @doc "Whether anything the Clear filters button would undo is set. A letter jump is not."
  @spec filtered?(t()) :: boolean()
  def filtered?(%__MODULE__{} = p), do: not same_listing?(%{p | letter: nil}, %__MODULE__{})

  @doc """
  Whether two URL states describe the same listing. `shown` and `above` only
  say how much of it is loaded, and change as the user scrolls.
  """
  @spec same_listing?(t(), t()) :: boolean()
  def same_listing?(%__MODULE__{} = a, %__MODULE__{} = b),
    do: %{a | shown: @first_page, above: 0} == %{b | shown: @first_page, above: 0}

  defp letter(value) when is_binary(value) do
    letter = String.downcase(value)
    if letter in LibraryListing.letters(), do: letter
  end

  defp letter(_value), do: nil

  defp monitored("true"), do: true
  defp monitored("false"), do: false
  defp monitored(_value), do: nil

  defp shown(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n |> max(@first_page) |> min(@max_shown)
      _ -> @first_page
    end
  end

  defp shown(_value), do: @first_page

  defp above(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n |> max(0) |> min(@max_shown)
      _ -> 0
    end
  end

  defp above(_value), do: 0
end
