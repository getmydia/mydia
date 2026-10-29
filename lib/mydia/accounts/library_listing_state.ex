defmodule Mydia.Accounts.LibraryListingState do
  @moduledoc """
  The sort and filters each library page last used, kept in the user's
  preferences under `"library_listing"`, keyed by page.
  """

  alias Mydia.Accounts
  alias Mydia.Accounts.User
  alias Mydia.Accounts.UserPreference

  @type pairs :: %{optional(String.t()) => String.t()}

  @doc """
  The sort and filters a library page last used, as URL query pairs, or `%{}`.

  `page` is `"movies"`, `"tv_shows"` or `"section:<collection id>"`. Anything
  malformed reads as `%{}`; the caller re-validates every value.
  """
  @spec get(User.t(), String.t()) :: pairs()
  def get(%User{} = user, page) when is_binary(page) do
    listing = Accounts.get_user_preference!(user).preferences["library_listing"]

    with true <- UserPreference.valid_library_listing?(listing),
         pairs when is_map(pairs) <- Map.get(listing, page) do
      pairs
    else
      _ -> %{}
    end
  end

  @doc """
  Saves a library page's sort and filters. Other pages' entries are kept:
  `Accounts.update_preference/2` merges only the top level, so the nested map
  is merged here.
  """
  @spec put(User.t(), String.t(), pairs()) :: :ok | {:error, Ecto.Changeset.t()}
  def put(%User{} = user, page, pairs) when is_binary(page) and is_map(pairs) do
    pref = Accounts.get_user_preference!(user)

    listing =
      case pref.preferences["library_listing"] do
        current when is_map(current) -> current
        _ -> %{}
      end

    case Accounts.update_preference(pref, %{"library_listing" => Map.put(listing, page, pairs)}) do
      {:ok, _pref} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end
end
