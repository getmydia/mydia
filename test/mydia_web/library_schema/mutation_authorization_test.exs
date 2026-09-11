defmodule MydiaWeb.LibrarySchema.MutationAuthorizationTest do
  @moduledoc """
  Mutations pass through the same fail-closed gate as queries: every root
  mutation field declares an action Policy knows, and a principal without it is
  refused before the resolver runs.
  """
  use MydiaWeb.ConnCase

  alias Mydia.LibraryApi.Policy
  alias Mydia.LibraryApi.Principal

  @user %Principal{role: "user", source: :api_key}

  test "every root mutation field declares an action Policy knows" do
    fields = Absinthe.Schema.lookup_type(MydiaWeb.LibrarySchema, :library_mutations).fields

    undeclared =
      for {name, field} <- fields,
          name not in [:__schema, :__type, :__typename],
          Absinthe.Type.meta(field, :action) not in Policy.actions(),
          do: name

    assert undeclared == []
  end

  test "an admin holds every mutation action" do
    admin = %Principal{role: "admin", source: :env}

    for action <- [:manage_library, :search, :manage_downloads, :read_events] do
      assert Policy.permit?(admin, action)
    end
  end

  test "a non-admin is refused before the resolver runs" do
    item = insert(:media_item, monitored: true)

    document = """
    mutation { setMediaItemMonitored(id: "#{item.id}", monitored: false) { mediaItem { id } } }
    """

    assert {:ok, %{errors: errors}} =
             Absinthe.run(document, MydiaWeb.LibrarySchema, context: %{principal: @user})

    assert Enum.any?(errors, &(&1.extensions[:code] == "FORBIDDEN"))
    assert Mydia.Media.get_media_item!(item.id).monitored
  end
end
