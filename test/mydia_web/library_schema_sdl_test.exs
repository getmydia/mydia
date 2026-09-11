defmodule MydiaWeb.LibrarySchemaSdlTest do
  @moduledoc """
  The committed SDL at priv/graphql/library.graphql is the Library API's contract.

  Unlike the player schema, nothing outside this repository consumes it, so it is
  not gated by the Rust parity test. It is gated here instead, so a field change
  shows up as a reviewable diff rather than only in the release notes.

  If this test fails, run `mix library_schema.export` and commit the result. Do
  not hand-edit the SDL file.
  """
  use ExUnit.Case, async: true

  @schema_path "priv/graphql/library.graphql"

  test "the committed SDL matches a fresh export of MydiaWeb.LibrarySchema" do
    committed = File.read!(@schema_path)
    exported = Absinthe.Schema.to_sdl(MydiaWeb.LibrarySchema)

    assert committed == exported, """
    #{@schema_path} is out of date.

    Regenerate it with:

        mix library_schema.export

    then commit the result.
    """
  end

  # The schema is separate from the player's, so it imports none of its types and
  # a collision is impossible. That also means Absinthe would happily export
  # `LibraryMediaItem` where the approved contract says `MediaItem`, so the names
  # the contract promised are pinned rather than left to the identifier prefix.
  test "type names are exactly the approved ones" do
    sdl = Absinthe.Schema.to_sdl(MydiaWeb.LibrarySchema)

    object_names = ~w(
      MediaItem Episode AvailabilityStatus LookupResult Download DownloadClient Indexer
      QualityProfile LibraryPath PageInfo MediaItemEdge MediaItemConnection
    )

    enum_names = ~w(
      MediaType MetadataProvider AvailabilityState DownloadFilter DownloadStatus
      ClientConfigState LibraryPathType
    )

    for name <- object_names do
      assert sdl =~ ~r/^type #{Regex.escape(name)}\b/m,
             "the SDL has no `type #{name}`. An Absinthe identifier like " <>
               "`:library_media_item` exports as `LibraryMediaItem`, so either rename the " <>
               "type or add `name: \"#{name}\"` to its declaration."
    end

    for name <- enum_names do
      assert sdl =~ ~r/^enum #{Regex.escape(name)}\b/m,
             "the SDL has no `enum #{name}`. See the note on type names above."
    end

    # And the prefixed forms must not exist, which is the failure this guards
    # against: a rename that leaves the export looking plausible.
    for name <- object_names ++ enum_names do
      refute sdl =~ ~r/^type Library#{Regex.escape(name)}\b/m
      refute sdl =~ ~r/^enum Library#{Regex.escape(name)}\b/m
    end
  end

  test "the root query fields are exactly the approved ones" do
    sdl = Absinthe.Schema.to_sdl(MydiaWeb.LibrarySchema)

    # Extract the RootQueryType block to avoid false matches in other types
    # (e.g., mediaItem exists both as a root query and as a Download field)
    root_query_match = Regex.run(~r/type RootQueryType \{(.*?)\n\}/s, sdl)

    assert root_query_match != nil,
           "could not find 'type RootQueryType { ... }' block in SDL. " <>
             "The schema structure has changed unexpectedly."

    [_, root_query_content] = root_query_match

    for field <- ~w(lookup mediaItem mediaItems downloads qualityProfiles libraryPaths) do
      assert root_query_content =~ ~r/^\s+#{field}[:(]/m,
             "the RootQueryType block has no `#{field}` query field"
    end
  end
end
