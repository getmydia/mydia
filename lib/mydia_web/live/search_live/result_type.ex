defmodule MydiaWeb.SearchLive.ResultType do
  @moduledoc """
  Decides whether a release on `/search` is a movie or a series.

  The indexer's Torznab category is trusted first. Public indexers often send
  no category at all, so the release title is parsed as a fallback; before
  that fallback existed, every uncategorized result disappeared under a type
  filter (#1104). The source is returned alongside the type so the page can
  mark a title-based guess as a guess.

  The badge, the type filter and the download modal's preselection all read
  this one function so they cannot disagree.
  """

  alias Mydia.Indexers.CategoryMapping
  alias Mydia.Indexers.SearchResult
  alias Mydia.Library.ReleaseParser

  @type kind :: :movies | :series | :unknown
  @type source :: :category | :title | :none

  @spec detect(SearchResult.t()) :: {kind(), source()}
  def detect(%SearchResult{category: category, title: title}) do
    case from_category(category) do
      nil -> from_title(title)
      kind -> {kind, :category}
    end
  end

  @spec media_type(kind()) :: :movie | :tv_show | nil
  def media_type(:movies), do: :movie
  def media_type(:series), do: :tv_show
  def media_type(_kind), do: nil

  defp from_category(id) when is_integer(id),
    do: video_kind(CategoryMapping.type_for_category(id))

  defp from_category(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, _rest} -> from_category(int)
      :error -> nil
    end
  end

  defp from_category(_category), do: nil

  defp video_kind(kind) when kind in [:movies, :series], do: kind
  defp video_kind(_kind), do: nil

  defp from_title(title) when is_binary(title) do
    case ReleaseParser.parse(title).type do
      :movie -> {:movies, :title}
      :tv_show -> {:series, :title}
      _ -> {:unknown, :none}
    end
  end

  defp from_title(_title), do: {:unknown, :none}
end
