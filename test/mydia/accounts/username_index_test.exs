defmodule Mydia.Accounts.UsernameIndexTest do
  # No database: build/1 takes a list and get/2 reads a map.
  use ExUnit.Case, async: true

  alias Mydia.Accounts.User
  alias Mydia.Accounts.UsernameIndex

  defp user(attrs), do: struct!(%User{id: Ecto.UUID.generate()}, attrs)

  describe "build/1" do
    test "keys each user by their downcased username" do
      tonix = user(username: "Tonix")

      assert UsernameIndex.build([tonix]) == %{"tonix" => tonix}
    end

    test "skips a user with no username" do
      # Every OIDC-provisioned account is this shape: oidc_changeset/2 never
      # casts :username and the column is nullable. One such account used to
      # take the whole seed job down with String.downcase(nil).
      sso = user(username: nil, email: "sso@example.test")
      tonix = user(username: "tonix")

      assert UsernameIndex.build([sso, tonix]) == %{"tonix" => tonix}
    end

    test "skips a user whose username is blank or only whitespace" do
      # A blank key is reachable from the lookup side: a nameless remote
      # profile would find it and be linked to a real person's account.
      assert UsernameIndex.build([user(username: "")]) == %{}
      assert UsernameIndex.build([user(username: "   ")]) == %{}
    end

    test "trims surrounding whitespace from the key" do
      tonix = user(username: " tonix ")

      assert UsernameIndex.build([tonix]) == %{"tonix" => tonix}
    end

    test "is empty for an empty list" do
      assert UsernameIndex.build([]) == %{}
    end
  end

  describe "get/2" do
    setup do
      tonix = user(username: "Tonix")
      {:ok, index: UsernameIndex.build([tonix]), tonix: tonix}
    end

    test "matches a remote name case-insensitively", %{index: index, tonix: tonix} do
      assert UsernameIndex.get(index, "TONIX") == tonix
      assert UsernameIndex.get(index, "tonix") == tonix
    end

    test "matches a remote name with surrounding whitespace", %{index: index, tonix: tonix} do
      assert UsernameIndex.get(index, "  Tonix  ") == tonix
    end

    test "returns nil for a name nobody has", %{index: index} do
      assert UsernameIndex.get(index, "nobody") == nil
    end

    test "returns nil for a nameless remote profile", %{index: index} do
      # Plex managed profiles and guest profiles carry a null username. They
      # match nobody rather than falling through to a "" lookup.
      assert UsernameIndex.get(index, nil) == nil
      assert UsernameIndex.get(index, "") == nil
      assert UsernameIndex.get(index, "   ") == nil
    end
  end
end
