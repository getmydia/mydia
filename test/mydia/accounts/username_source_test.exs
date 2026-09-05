defmodule Mydia.Accounts.UsernameSourceTest do
  use ExUnit.Case, async: true

  alias Mydia.Accounts.UsernameSource

  describe "derive/1 tiers" do
    test "prefers the IdP claim" do
      attrs = %{
        preferred_username: "tonix",
        email: "robin@example.test",
        oidc_sub: "abcdef1234567890"
      }

      assert UsernameSource.derive(attrs) == {:idp, "tonix"}
    end

    test "falls back to the email local part when there is no claim" do
      attrs = %{email: "robin.vega@example.test", oidc_sub: "abcdef1234567890"}

      assert UsernameSource.derive(attrs) == {:email, "robin.vega"}
    end

    test "falls back to a sub prefix when there is no email" do
      assert UsernameSource.derive(%{oidc_sub: "abcdef1234567890"}) == {:sub, "oidc-abcdef12"}
    end

    test "returns :none when every tier is absent" do
      assert UsernameSource.derive(%{}) == :none
    end

    test "skips a tier that slugs to fewer than three characters" do
      attrs = %{preferred_username: "ab", email: "robin@example.test", oidc_sub: "s1"}

      assert UsernameSource.derive(attrs) == {:email, "robin"}
    end

    test "reads a %User{} struct as readily as an attrs map" do
      user = %Mydia.Accounts.User{email: "robin@example.test", oidc_sub: "abcdef1234567890"}

      assert UsernameSource.derive(user) == {:email, "robin"}
    end
  end

  describe "derive/1 slugging" do
    test "downcases and replaces characters a username may not hold" do
      assert UsernameSource.derive(%{preferred_username: "Robin Vega!"}) == {:idp, "robin-vega"}
    end

    test "collapses runs of separators and trims them from both ends" do
      assert UsernameSource.derive(%{preferred_username: "--robin__vega--"}) ==
               {:idp, "robin-vega"}
    end

    test "truncates to fifty characters without leaving a trailing separator" do
      claim = String.duplicate("a", 49) <> " tail"

      {:idp, slug} = UsernameSource.derive(%{preferred_username: claim})

      assert String.length(slug) == 49
      assert slug == String.duplicate("a", 49)
    end
  end

  describe "suffixed/2" do
    test "leaves the first attempt alone" do
      assert UsernameSource.suffixed("robin", 1) == "robin"
    end

    test "appends the attempt number from the second attempt on" do
      assert UsernameSource.suffixed("robin", 2) == "robin-2"
      assert UsernameSource.suffixed("robin", 17) == "robin-17"
    end

    test "keeps the suffixed name inside the length limit" do
      slug = String.duplicate("a", 50)

      assert UsernameSource.suffixed(slug, 12) == String.duplicate("a", 47) <> "-12"
      assert String.length(UsernameSource.suffixed(slug, 12)) == 50
    end
  end

  describe "upgrade?/3" do
    test "always writes when there is no username yet" do
      assert UsernameSource.upgrade?(nil, nil, :sub)
      assert UsernameSource.upgrade?("", nil, :sub)
      assert UsernameSource.upgrade?("   ", nil, :sub)
    end

    test "never touches a name with no recorded source" do
      refute UsernameSource.upgrade?("robin", nil, :idp)
    end

    test "moves up the tiers" do
      assert UsernameSource.upgrade?("oidc-abcdef12", "sub", :email)
      assert UsernameSource.upgrade?("robin", "email", :idp)
    end

    test "never moves down and never rewrites the same tier" do
      refute UsernameSource.upgrade?("tonix", "idp", :email)
      refute UsernameSource.upgrade?("tonix", "idp", :sub)
      refute UsernameSource.upgrade?("tonix", "idp", :idp)
      refute UsernameSource.upgrade?("robin", "email", :email)
    end
  end
end
