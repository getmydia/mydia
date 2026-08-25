defmodule Mydia.Accounts.Authorization do
  @moduledoc """
  Authorization helpers for checking user permissions.

  Provides a centralized way to check if a user can perform specific actions
  based on their role.
  """

  alias Mydia.Accounts.User

  @role_hierarchy %{
    "admin" => 4,
    "user" => 3,
    "readonly" => 2,
    "guest" => 1
  }

  @doc """
  Checks if a user has the required role or higher in the hierarchy.

  ## Examples

      iex> user = %User{role: "admin"}
      iex> has_role?(user, :user)
      true

      iex> user = %User{role: "guest"}
      iex> has_role?(user, :admin)
      false
  """
  def has_role?(user, required_role)
  def has_role?(nil, _required_role), do: false

  def has_role?(%User{role: user_role}, required_role) do
    user_level = Map.get(@role_hierarchy, user_role, 0)
    required_level = Map.get(@role_hierarchy, to_string(required_role), 999)

    user_level >= required_level
  end

  @doc """
  Checks if a user can create media items.

  Only admin and user roles can create media items.
  Guests and readonly users cannot create media.

  Also accepts a `Mydia.Accounts.Scope`, delegating to its user. A restricted
  account keeps whatever its role allows: the category and rating limits are
  enforced per item in `Mydia.Media`, not by removing the ability to create
  anything at all, so an operator can give an account a rating limit without
  demoting it.
  """
  def can_create_media?(user)
  def can_create_media?(%Mydia.Accounts.Scope{user: user}), do: can_create_media?(user)
  def can_create_media?(nil), do: false
  def can_create_media?(%User{role: role}) when role in ["admin", "user"], do: true
  def can_create_media?(_user), do: false

  @doc """
  Checks if a user can update media items.

  Only admin and user roles can update media items.
  Guests and readonly users cannot update media.

  Also accepts a `Mydia.Accounts.Scope`, delegating to its user. A restricted
  account keeps whatever its role allows: the category and rating limits are
  enforced per item in `Mydia.Media`, not by removing the ability to update
  anything at all, so an operator can give an account a rating limit without
  demoting it.
  """
  def can_update_media?(user)
  def can_update_media?(%Mydia.Accounts.Scope{user: user}), do: can_update_media?(user)
  def can_update_media?(nil), do: false
  def can_update_media?(%User{role: role}) when role in ["admin", "user"], do: true
  def can_update_media?(_user), do: false

  @doc """
  Checks if a user can delete media items.

  Only admin and user roles can delete media items.
  Guests and readonly users cannot delete media.

  Also accepts a `Mydia.Accounts.Scope`, delegating to its user. A restricted
  account keeps whatever its role allows: the category and rating limits are
  enforced per item in `Mydia.Media`, not by removing the ability to delete
  anything at all, so an operator can give an account a rating limit without
  demoting it.
  """
  def can_delete_media?(user)
  def can_delete_media?(%Mydia.Accounts.Scope{user: user}), do: can_delete_media?(user)
  def can_delete_media?(nil), do: false
  def can_delete_media?(%User{role: role}) when role in ["admin", "user"], do: true
  def can_delete_media?(_user), do: false

  @doc """
  Checks if a user can view media items.

  All authenticated users can view media items.

  Also accepts a `Mydia.Accounts.Scope`, delegating to its user.
  """
  def can_view_media?(user)
  def can_view_media?(%Mydia.Accounts.Scope{user: user}), do: can_view_media?(user)
  def can_view_media?(nil), do: false
  def can_view_media?(%User{}), do: true

  @doc """
  Checks if a user can submit media requests.

  Only guest users can submit media requests.
  Higher-level users should create media directly.

  Also accepts a `Mydia.Accounts.Scope`, delegating to its user.
  """
  def can_submit_request?(user)
  def can_submit_request?(%Mydia.Accounts.Scope{user: user}), do: can_submit_request?(user)
  def can_submit_request?(nil), do: false
  def can_submit_request?(%User{role: "guest"}), do: true
  def can_submit_request?(_user), do: false

  @doc """
  Checks if a user can approve or reject media requests.

  Only admins can approve or reject media requests.
  """
  def can_manage_requests?(user)
  def can_manage_requests?(nil), do: false
  def can_manage_requests?(%User{role: "admin"}), do: true
  def can_manage_requests?(_user), do: false

  @doc """
  Checks if a user is an admin.
  """
  def is_admin?(user)
  def is_admin?(nil), do: false
  def is_admin?(%User{role: "admin"}), do: true
  def is_admin?(_user), do: false

  @doc """
  Checks if a user is a guest.
  """
  def is_guest?(user)
  def is_guest?(nil), do: false
  def is_guest?(%User{role: "guest"}), do: true
  def is_guest?(_user), do: false

  @doc """
  Returns the role hierarchy map.
  """
  def role_hierarchy, do: @role_hierarchy

  @doc """
  Returns the numeric level for a given role.
  """
  def role_level(role) when is_binary(role) do
    Map.get(@role_hierarchy, role, 0)
  end

  def role_level(role) when is_atom(role) do
    Map.get(@role_hierarchy, to_string(role), 0)
  end
end
