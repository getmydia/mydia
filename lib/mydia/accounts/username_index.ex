defmodule Mydia.Accounts.UsernameIndex do
  @moduledoc """
  A case-insensitive index of Mydia users by username, for matching them
  against a media server's account names.

  Both halves of the match live here on purpose. `build/1` decides what a key
  looks like and `get/2` decides how a remote name is turned into one, so the
  two sides cannot drift apart. They did drift: the seeds guarded the remote
  name with `name || ""` and then looked that up in an index that had been
  built without any guard at all, which crashed on the first
  OIDC-provisioned user and, had it not crashed, would have matched a nameless
  remote profile against a blank Mydia username.

  Users with no usable username are absent from the index rather than keyed
  under `""`. That is now an edge case rather than the norm: OIDC accounts are
  named at login by `Mydia.Accounts.UsernameSource`, and existing ones were
  named by the backfill migration. What is left is the rows the backfill could
  not name, which stay `nil` on purpose so a migration never fails a boot. The
  operator maps those by hand in the account-mapping modal.
  """

  alias Mydia.Accounts.User

  @type t :: %{String.t() => User.t()}

  @doc """
  Indexes users by their normalised username, skipping those without one.
  """
  @spec build([User.t()]) :: t()
  def build(users) do
    users
    |> Enum.map(fn %User{} = user -> {normalize(user.username), user} end)
    |> Enum.reject(fn {key, _user} -> is_nil(key) end)
    |> Map.new()
  end

  @doc """
  Returns the user a remote account name matches, or `nil`.

  A name that normalises to nothing matches nobody, which is the whole point:
  a lookup of `""` could otherwise succeed.
  """
  @spec get(t(), String.t() | nil) :: User.t() | nil
  def get(index, name) do
    case normalize(name) do
      nil -> nil
      key -> Map.get(index, key)
    end
  end

  defp normalize(name) when is_binary(name) do
    case String.trim(name) do
      "" -> nil
      trimmed -> String.downcase(trimmed)
    end
  end

  defp normalize(_name), do: nil
end
