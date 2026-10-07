defmodule MydiaWeb.MediaLive.Index.ListingParams do
  @moduledoc """
  The library listing's URL state: search, filters, sort and how many rows are
  on screen.

  Keeping it in the URL is what lets Back from a title restore the list as it
  was. Default values are left out of the URL, so an untouched page keeps a
  bare path. Anything unrecognised parses to its default.
  """

  alias Mydia.Media.LibraryListing

  @first_page 50
  @max_shown 1000
  @default_sort "title_asc"
  @progress %{"missing" => :missing, "partial" => :partial, "downloaded" => :downloaded}
  @qualities ~w(720p 1080p 2160p)

  defstruct search: "",
            library: nil,
            progress: nil,
            monitored: nil,
            quality: nil,
            sort: @default_sort,
            shown: @first_page

  @type t :: %__MODULE__{
          search: String.t(),
          library: binary() | nil,
          progress: :missing | :partial | :downloaded | nil,
          monitored: boolean() | nil,
          quality: String.t() | nil,
          sort: String.t(),
          shown: pos_integer()
        }

  @spec first_page() :: pos_integer()
  def first_page, do: @first_page

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
      shown: shown(params["shown"])
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
      {"shown", if(p.shown == @first_page, do: nil, else: Integer.to_string(p.shown))}
    ]
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
  end

  @spec path(String.t(), t()) :: String.t()
  def path(base, %__MODULE__{} = p) do
    case to_query(p) do
      [] -> base
      query -> base <> "?" <> URI.encode_query(query)
    end
  end

  @doc "Whether anything the Clear filters button would undo is set."
  @spec filtered?(t()) :: boolean()
  def filtered?(%__MODULE__{} = p), do: not same_listing?(p, %__MODULE__{})

  @spec same_listing?(t(), t()) :: boolean()
  def same_listing?(%__MODULE__{} = a, %__MODULE__{} = b),
    do: %{a | shown: @first_page} == %{b | shown: @first_page}

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
end
