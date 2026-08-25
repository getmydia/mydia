defmodule Mydia.Accounts.Scope do
  @moduledoc """
  The acting user plus their resolved media access restrictions.

  Every `Mydia.Media` function that reads or writes media takes one of these as
  a required first argument. That is deliberate: a required argument turns a
  call site that forgets to scope into a compile error, where an implicit
  mechanism would turn it into a silent leak that a restricted account finds
  before anyone else does.

  Three constructors, with different meanings:

    * `for_user/1` resolves a real request. Admins come back unrestricted.
    * `system/0` is background work with no acting user: scans, imports, Oban
      jobs. Every intentional bypass is therefore greppable.
    * `unrestricted/0` is for tests that do not care about restrictions.

  This struct holds data only. Query composition lives in
  `Mydia.Media.Restrictions`.
  """

  alias Mydia.Accounts
  alias Mydia.Accounts.AccessRestriction
  alias Mydia.Accounts.User

  @enforce_keys [:user]
  defstruct [:user, :allowed_categories, :max_content_age]

  @type t :: %__MODULE__{
          user: User.t() | nil,
          allowed_categories: [String.t()] | nil,
          max_content_age: integer() | nil
        }

  @doc """
  Builds the scope for a user, loading their restriction row if there is one.
  """
  @spec for_user(User.t()) :: t()
  def for_user(%User{role: "admin"} = user), do: %__MODULE__{user: user}

  def for_user(%User{} = user) do
    case Accounts.get_access_restriction(user) do
      nil ->
        %__MODULE__{user: user}

      %AccessRestriction{} = restriction ->
        %__MODULE__{
          user: user,
          allowed_categories: presence(restriction.allowed_categories),
          max_content_age: restriction.max_content_age
        }
    end
  end

  @doc """
  The scope for background work with no acting user. Unrestricted by design.
  """
  @spec system() :: t()
  def system, do: %__MODULE__{user: nil}

  @doc """
  An unrestricted scope with no user, for tests that do not exercise limits.
  """
  @spec unrestricted() :: t()
  def unrestricted, do: %__MODULE__{user: nil}

  @doc """
  True when this scope limits anything at all.
  """
  @spec restricted?(t()) :: boolean()
  def restricted?(%__MODULE__{allowed_categories: nil, max_content_age: nil}), do: false
  def restricted?(%__MODULE__{}), do: true

  # An empty list is an admin who ticked nothing, which means "no category
  # limit". Treating it as "deny everything" would lock an account out of the
  # whole library on a mis-click.
  defp presence([]), do: nil
  defp presence(nil), do: nil
  defp presence(list) when is_list(list), do: list
end
