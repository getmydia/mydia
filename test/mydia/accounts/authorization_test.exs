defmodule Mydia.Accounts.AuthorizationTest do
  use Mydia.DataCase, async: true

  alias Mydia.Accounts.{Authorization, Scope, User}

  describe "has_role?/2" do
    test "returns true when user has exact role" do
      user = %User{role: "admin"}
      assert Authorization.has_role?(user, :admin)
    end

    test "returns true when user has higher role in hierarchy" do
      user = %User{role: "admin"}
      assert Authorization.has_role?(user, :user)
      assert Authorization.has_role?(user, :readonly)
      assert Authorization.has_role?(user, :guest)
    end

    test "returns false when user has lower role in hierarchy" do
      user = %User{role: "guest"}
      refute Authorization.has_role?(user, :admin)
      refute Authorization.has_role?(user, :user)
      refute Authorization.has_role?(user, :readonly)
    end

    test "returns false for nil user" do
      refute Authorization.has_role?(nil, :admin)
    end
  end

  describe "can_create_media?/1" do
    test "returns true for admin users" do
      user = %User{role: "admin"}
      assert Authorization.can_create_media?(user)
    end

    test "returns true for user role" do
      user = %User{role: "user"}
      assert Authorization.can_create_media?(user)
    end

    test "returns false for readonly users" do
      user = %User{role: "readonly"}
      refute Authorization.can_create_media?(user)
    end

    test "returns false for guest users" do
      user = %User{role: "guest"}
      refute Authorization.can_create_media?(user)
    end

    test "returns false for nil user" do
      refute Authorization.can_create_media?(nil)
    end
  end

  describe "can_create_media?/1 with a scope" do
    test "delegates to the scope's user, restrictions notwithstanding" do
      assert Authorization.can_create_media?(%Scope{user: %User{role: "user"}})
      refute Authorization.can_create_media?(%Scope{user: %User{role: "guest"}})
    end
  end

  describe "can_update_media?/1" do
    test "returns true for admin users" do
      user = %User{role: "admin"}
      assert Authorization.can_update_media?(user)
    end

    test "returns true for user role" do
      user = %User{role: "user"}
      assert Authorization.can_update_media?(user)
    end

    test "returns false for readonly users" do
      user = %User{role: "readonly"}
      refute Authorization.can_update_media?(user)
    end

    test "returns false for guest users" do
      user = %User{role: "guest"}
      refute Authorization.can_update_media?(user)
    end

    test "returns false for nil user" do
      refute Authorization.can_update_media?(nil)
    end
  end

  describe "can_update_media?/1 with a scope" do
    test "delegates to the scope's user" do
      assert Authorization.can_update_media?(%Scope{user: %User{role: "user"}})
      refute Authorization.can_update_media?(%Scope{user: %User{role: "guest"}})
    end
  end

  describe "can_delete_media?/1" do
    test "returns true for admin users" do
      user = %User{role: "admin"}
      assert Authorization.can_delete_media?(user)
    end

    test "returns true for user role" do
      user = %User{role: "user"}
      assert Authorization.can_delete_media?(user)
    end

    test "returns false for readonly users" do
      user = %User{role: "readonly"}
      refute Authorization.can_delete_media?(user)
    end

    test "returns false for guest users" do
      user = %User{role: "guest"}
      refute Authorization.can_delete_media?(user)
    end

    test "returns false for nil user" do
      refute Authorization.can_delete_media?(nil)
    end
  end

  describe "can_delete_media?/1 with a scope" do
    test "delegates to the scope's user" do
      assert Authorization.can_delete_media?(%Scope{user: %User{role: "user"}})
      refute Authorization.can_delete_media?(%Scope{user: %User{role: "guest"}})
    end
  end

  describe "can_view_media?/1" do
    test "returns true for all authenticated users" do
      assert Authorization.can_view_media?(%User{role: "admin"})
      assert Authorization.can_view_media?(%User{role: "user"})
      assert Authorization.can_view_media?(%User{role: "readonly"})
      assert Authorization.can_view_media?(%User{role: "guest"})
    end

    test "returns false for nil user" do
      refute Authorization.can_view_media?(nil)
    end
  end

  describe "can_view_media?/1 with a scope" do
    test "delegates to the scope's user" do
      assert Authorization.can_view_media?(%Scope{user: %User{role: "guest"}})
      refute Authorization.can_view_media?(%Scope{user: nil})
    end
  end

  describe "can_submit_request?/1" do
    test "returns true for guest users" do
      user = %User{role: "guest"}
      assert Authorization.can_submit_request?(user)
    end

    test "returns false for non-guest users" do
      refute Authorization.can_submit_request?(%User{role: "admin"})
      refute Authorization.can_submit_request?(%User{role: "user"})
      refute Authorization.can_submit_request?(%User{role: "readonly"})
    end

    test "returns false for nil user" do
      refute Authorization.can_submit_request?(nil)
    end
  end

  describe "can_submit_request?/1 with a scope" do
    test "delegates to the scope's user" do
      assert Authorization.can_submit_request?(%Scope{user: %User{role: "guest"}})
      refute Authorization.can_submit_request?(%Scope{user: %User{role: "admin"}})
    end
  end

  describe "can_manage_requests?/1" do
    test "returns true for admin users" do
      user = %User{role: "admin"}
      assert Authorization.can_manage_requests?(user)
    end

    test "returns false for non-admin users" do
      refute Authorization.can_manage_requests?(%User{role: "user"})
      refute Authorization.can_manage_requests?(%User{role: "readonly"})
      refute Authorization.can_manage_requests?(%User{role: "guest"})
    end

    test "returns false for nil user" do
      refute Authorization.can_manage_requests?(nil)
    end
  end

  describe "is_admin?/1" do
    test "returns true for admin users" do
      user = %User{role: "admin"}
      assert Authorization.is_admin?(user)
    end

    test "returns false for non-admin users" do
      refute Authorization.is_admin?(%User{role: "user"})
      refute Authorization.is_admin?(%User{role: "readonly"})
      refute Authorization.is_admin?(%User{role: "guest"})
    end

    test "returns false for nil user" do
      refute Authorization.is_admin?(nil)
    end
  end

  describe "is_guest?/1" do
    test "returns true for guest users" do
      user = %User{role: "guest"}
      assert Authorization.is_guest?(user)
    end

    test "returns false for non-guest users" do
      refute Authorization.is_guest?(%User{role: "admin"})
      refute Authorization.is_guest?(%User{role: "user"})
      refute Authorization.is_guest?(%User{role: "readonly"})
    end

    test "returns false for nil user" do
      refute Authorization.is_guest?(nil)
    end
  end

  describe "role_hierarchy/0" do
    test "returns the role hierarchy map" do
      hierarchy = Authorization.role_hierarchy()
      assert is_map(hierarchy)
      assert hierarchy["admin"] == 4
      assert hierarchy["user"] == 3
      assert hierarchy["readonly"] == 2
      assert hierarchy["guest"] == 1
    end
  end

  describe "role_level/1" do
    test "returns correct level for string roles" do
      assert Authorization.role_level("admin") == 4
      assert Authorization.role_level("user") == 3
      assert Authorization.role_level("readonly") == 2
      assert Authorization.role_level("guest") == 1
    end

    test "returns correct level for atom roles" do
      assert Authorization.role_level(:admin) == 4
      assert Authorization.role_level(:user) == 3
      assert Authorization.role_level(:readonly) == 2
      assert Authorization.role_level(:guest) == 1
    end

    test "returns 0 for unknown roles" do
      assert Authorization.role_level("unknown") == 0
      assert Authorization.role_level(:unknown) == 0
    end
  end
end
