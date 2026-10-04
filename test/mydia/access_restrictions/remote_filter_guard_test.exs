defmodule Mydia.AccessRestrictions.RemoteFilterGuardTest do
  @moduledoc """
  Every user-facing module that pulls titles from the metadata catalog must
  pass them through `Mydia.Media.RemoteFilter`, directly or through a helper
  that does. A new surface that forgets is how restricted accounts saw
  everything on Discover (#1000).

  Limits: the scan is file-granular and textual. A second, unfiltered catalog
  call next to a filtered one in the same file is not caught, so a reviewer
  must check every new catalog call by hand. Whole-line `#` comments are
  ignored; a `#` after code on the same line is not.
  """
  use ExUnit.Case, async: true

  # Cached and uncached variants alike: `search` is the free-text TMDB search
  # behind /search and /import (both in the :authenticated live_session).
  @catalog_calls ~w(search search_cached fetch_trending fetch_curated_list discover trending_movies trending_tv_shows fetch_recommendations_by_ref_cached)

  # Helpers that filter internally, so a caller of one needs no RemoteFilter
  # of its own.
  @filtered_helpers ~w(Recommendations.for_ref( Recommendations.for_media_item( Franchises.for_media_item()

  # Each entry names why it is exempt.
  @allowed MapSet.new([
             # `lookup` is served by the Library API, which only admits admin
             # keys (see `LibraryApiAuth`), and an admin is never restricted.
             "lib/mydia_web/library_schema/resolvers/lookup.ex"
           ])

  @doc false
  def offender?(source) do
    code = strip_comment_lines(source)
    calls_catalog?(code) and not filtered?(code)
  end

  # A comment that names `RemoteFilter.` must not exempt a file.
  defp strip_comment_lines(source) do
    source
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(String.trim_leading(&1), "#"))
    |> Enum.join("\n")
  end

  defp calls_catalog?(source) do
    code = strip_comment_lines(source)
    Enum.any?(@catalog_calls, &(code =~ "Metadata.#{&1}("))
  end

  defp filtered?(source) do
    source =~ "RemoteFilter." or Enum.any?(@filtered_helpers, &(source =~ &1))
  end

  test "user-facing catalog callers go through RemoteFilter" do
    offenders =
      (Path.wildcard("lib/mydia_web/**/*.ex") ++ Path.wildcard("lib/mydia/plugins/**/*.ex"))
      |> Enum.reject(&MapSet.member?(@allowed, &1))
      |> Enum.filter(&offender?(File.read!(&1)))

    assert offenders == [],
           "these modules fetch catalog titles without RemoteFilter: #{inspect(offenders)}"
  end

  test "the allowlist only names files that still exist and still call the catalog" do
    for path <- @allowed do
      assert File.exists?(path), "stale allowlist entry: #{path}"
      assert calls_catalog?(File.read!(path)), "allowlist entry no longer needed: #{path}"
    end
  end

  describe "the scan can fail" do
    test "flags a catalog call with no filtering" do
      assert offender?("""
             defmodule Leaky do
               def rows, do: Mydia.Metadata.trending_movies(config)
             end
             """)
    end

    test "passes a direct RemoteFilter caller" do
      refute offender?("""
             defmodule Wired do
               def rows, do: Metadata.search_cached(c, q) |> RemoteFilter.filter(scope)
             end
             """)
    end

    test "passes a caller of a helper that filters internally" do
      refute offender?("""
             defmodule ViaHelper do
               def rows, do: Metadata.discover(c) && Recommendations.for_ref(scope, ref)
             end
             """)
    end

    test "a comment that mentions RemoteFilter does not exempt the file" do
      assert offender?("""
             defmodule Leaky do
               # TODO: pipe this through RemoteFilter.filter/2 and Recommendations.for_ref(
               def rows, do: Metadata.search(c, q)
             end
             """)
    end

    test "flags a module wired before its RemoteFilter call is removed" do
      wired = "Metadata.fetch_curated_list(c, :x) |> RemoteFilter.filter(scope)"
      refute offender?(wired)
      assert offender?(String.replace(wired, "RemoteFilter.", "Enum."))
    end
  end
end
