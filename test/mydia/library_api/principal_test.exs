defmodule Mydia.LibraryApi.PrincipalTest do
  use ExUnit.Case, async: true

  alias Mydia.Accounts.User
  alias Mydia.LibraryApi.Principal

  test "a database key acts as its owner" do
    principal = %Principal{role: "admin", source: :api_key, user: %User{id: "owner-id"}}

    assert Principal.actor_opts(principal) == [actor_type: :user, actor_id: "owner-id"]
  end

  test "the environment key acts as the system under a fixed name" do
    assert Principal.actor_opts(%Principal{role: "admin", source: :env}) ==
             [actor_type: :system, actor_id: "library_api_key"]
  end
end
