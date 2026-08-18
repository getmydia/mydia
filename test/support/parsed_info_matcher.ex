defmodule Mydia.Library.ParsedInfoMatcher do
  @moduledoc """
  A matcher whose match map carries real `parsed_info`, the way
  `MetadataMatcher.match_file/2` does.

  `EchoMatcher` and `FailingMatcher` deliberately omit `parsed_info` from their
  match maps, which is exactly why `BatchMatcher.reuse/2` copying the head
  file's `parsed_info` onto every tail file went unnoticed by every prior
  anchor-grouping test: the field they'd have needed to disagree on was never
  populated on either side. This matcher parses each path for real (season and
  episode included) so a test can assert that a tail file keeps its own parsed
  season/episode rather than inheriting the head's.
  """

  @behaviour Mydia.Library.Matcher

  alias Mydia.Library.ReleaseParser

  @impl true
  def match_file(path, _opts) do
    parsed = ReleaseParser.parse_with_path(path)

    {:ok,
     %{
       provider_id: "stub",
       provider_type: :tvdb,
       title: parsed.title || Path.basename(path),
       year: parsed.year,
       match_confidence: 1.0,
       parsed_info: parsed
     }}
  end
end
