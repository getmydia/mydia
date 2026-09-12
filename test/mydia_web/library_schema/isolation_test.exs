defmodule MydiaWeb.LibrarySchema.IsolationTest do
  @moduledoc """
  The p2p server runs GraphQL against `MydiaWeb.Schema`. A Library API field must
  not be reachable through it, and no library query may resolve without a
  principal.
  """
  use MydiaWeb.ConnCase

  alias Mydia.P2p.Server

  test "a library-only field is a validation error on the player schema" do
    result = Server.run_graphql("{ qualityProfiles { id } }", %{}, nil, %{})

    assert {:ok, %{errors: errors}} = result
    assert errors != []
    assert Enum.any?(errors, &(&1.message =~ "qualityProfiles"))
  end

  test "the player schema still rejects an unauthenticated player field" do
    result = Server.run_graphql("{ movies { edges { node { id } } } }", %{}, nil, %{})

    assert {:ok, %{errors: errors}} = result
    assert Enum.any?(errors, &(&1.message =~ "Authentication required"))
  end
end
