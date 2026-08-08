defmodule MydiaWeb.SchemaSdlTest do
  @moduledoc """
  The committed SDL at player/lib/graphql/schema.graphql is the contract
  shared by the Elixir server, the Rust server, and the Flutter player.

  If this test fails, the Elixir schema changed without the contract file
  being regenerated. Run `mix schema.export` and commit the result. Do not
  hand-edit the SDL file.
  """
  use ExUnit.Case, async: true

  @schema_path "player/lib/graphql/schema.graphql"

  test "committed SDL matches a fresh export of MydiaWeb.Schema" do
    committed = File.read!(@schema_path)
    exported = Absinthe.Schema.to_sdl(MydiaWeb.Schema)

    assert committed == exported, """
    player/lib/graphql/schema.graphql is out of date.

    Regenerate it with:

        mix schema.export

    then commit the result.
    """
  end
end
