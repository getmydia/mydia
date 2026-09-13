defmodule Mydia.Accounts.HomeLayout.Widget do
  @moduledoc """
  Represents a customizable widget definition on the home dashboard.
  """
  @enforce_keys [:key, :label, :description, :roles, :default?]
  defstruct [:key, :label, :description, :roles, :default?]

  @type t :: %__MODULE__{
          key: atom(),
          label: String.t(),
          description: String.t(),
          roles: [String.t()] | :all,
          default?: boolean()
        }
end

defmodule Mydia.Accounts.HomeLayout do
  @moduledoc """
  Pure domain module defining dashboard home widgets, role-based availability,
  defaults, and layout resolution.
  """

  alias Mydia.Accounts.HomeLayout.Widget
  alias Mydia.Accounts.User

  @catalog [
    %Widget{
      key: :library_stats,
      label: "Library stats",
      description: "Movies, TV shows, downloads, and storage counters",
      roles: :all,
      default?: true
    },
    %Widget{
      key: :system_health,
      label: "System health",
      description: "Health status for clients, indexers, media servers, duplicates, and trash",
      roles: ["admin"],
      default?: true
    },
    %Widget{
      key: :quick_actions,
      label: "Quick actions",
      description: "Shortcuts to add, import, or request media",
      roles: :all,
      default?: true
    },
    %Widget{
      key: :recently_added,
      label: "Recently added",
      description: "Recently added movies and TV shows",
      roles: :all,
      default?: true
    },
    %Widget{
      key: :recently_added_movies,
      label: "Recently added movies",
      description: "Recently added movies only",
      roles: :all,
      default?: false
    },
    %Widget{
      key: :recently_added_tv,
      label: "Recently added TV shows",
      description: "Recently added TV shows only",
      roles: :all,
      default?: false
    },
    %Widget{
      key: :trending_movies,
      label: "Trending movies",
      description: "Trending movies rail",
      roles: :all,
      default?: true
    },
    %Widget{
      key: :trending_tv,
      label: "Trending TV shows",
      description: "Trending TV shows rail",
      roles: :all,
      default?: true
    },
    %Widget{
      key: :episodes,
      label: "Your activity",
      description: "Recently aired and coming soon episodes",
      roles: :all,
      default?: true
    }
  ]

  @key_map Map.new(@catalog, fn %Widget{key: k} = w -> {k, w} end)
  @string_key_map Map.new(@catalog, fn %Widget{key: k} = w -> {to_string(k), w} end)

  @doc "Returns the full widget catalog in display order."
  @spec catalog() :: [Widget.t()]
  def catalog, do: @catalog

  @doc "Returns all known widget keys as atoms."
  @spec valid_keys() :: [atom()]
  def valid_keys, do: Enum.map(@catalog, & &1.key)

  @doc "Returns all known widget keys as strings."
  @spec valid_key_strings() :: [String.t()]
  def valid_key_strings, do: Enum.map(@catalog, &to_string(&1.key))

  @doc "Finds a widget struct by atom or string key."
  @spec get_widget(atom() | String.t()) :: Widget.t() | nil
  def get_widget(key) when is_atom(key), do: Map.get(@key_map, key)
  def get_widget(key) when is_binary(key), do: Map.get(@string_key_map, key)
  def get_widget(_), do: nil

  @doc "Converts a string or atom to a valid widget key atom, or nil if unknown."
  @spec to_key(atom() | String.t()) :: atom() | nil
  def to_key(key) when is_atom(key) do
    if Map.has_key?(@key_map, key), do: key, else: nil
  end

  def to_key(key) when is_binary(key) do
    case Map.get(@string_key_map, key) do
      %Widget{key: k} -> k
      nil -> nil
    end
  end

  def to_key(_), do: nil

  @doc "Converts an atom or string key to its string form."
  @spec to_string_key(atom() | String.t()) :: String.t()
  def to_string_key(key) when is_atom(key), do: Atom.to_string(key)
  def to_string_key(key) when is_binary(key), do: key

  @doc "Returns catalog entries available to the given user or role."
  @spec available(User.t() | String.t() | nil) :: [Widget.t()]
  def available(%User{role: role}), do: available(role)
  def available(nil), do: available("guest")

  def available(role) when is_binary(role) do
    Enum.filter(@catalog, fn widget ->
      widget.roles == :all or role in widget.roles
    end)
  end

  @doc "Returns the default visible keys for the given user or role in order."
  @spec default_keys(User.t() | String.t() | nil) :: [atom()]
  def default_keys(user_or_role) do
    user_or_role
    |> available()
    |> Enum.filter(& &1.default?)
    |> Enum.map(& &1.key)
  end

  @doc """
  Resolves stored preference into an ordered list of visible widget key atoms.
  Nil or non-list returns default_keys/1.
  An empty list stays empty.
  List items are filtered to known, role-permitted, de-duplicated keys in stored order.
  """
  @spec resolve(User.t() | String.t() | nil, [String.t() | atom()] | term()) :: [atom()]
  def resolve(user_or_role, stored) do
    if is_nil(stored) or not is_list(stored) do
      default_keys(user_or_role)
    else
      allowed_keys = MapSet.new(Enum.map(available(user_or_role), & &1.key))

      stored
      |> Enum.reduce({[], MapSet.new()}, fn item, {acc, seen} ->
        key = to_key(item)

        if key && MapSet.member?(allowed_keys, key) && not MapSet.member?(seen, key) do
          {acc ++ [key], MapSet.put(seen, key)}
        else
          {acc, seen}
        end
      end)
      |> elem(0)
    end
  end

  @doc "Returns available widget keys not currently in `visible_keys`, in catalog order."
  @spec hidden(User.t() | String.t() | nil, [atom() | String.t()]) :: [atom()]
  def hidden(user_or_role, visible_keys) do
    visible_set =
      visible_keys
      |> Enum.map(&to_key/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    user_or_role
    |> available()
    |> Enum.map(& &1.key)
    |> Enum.reject(&MapSet.member?(visible_set, &1))
  end

  @doc "Toggles a widget key in the visible list: removes if present, appends if absent."
  @spec toggle([atom()], atom() | String.t()) :: [atom()]
  def toggle(visible_keys, key) do
    case to_key(key) do
      nil ->
        visible_keys

      atom_key ->
        if atom_key in visible_keys do
          List.delete(visible_keys, atom_key)
        else
          visible_keys ++ [atom_key]
        end
    end
  end

  @doc "Moves a widget key up or down in the visible list. No-op at edges or if not visible."
  @spec move([atom()], atom() | String.t(), :up | :down) :: [atom()]
  def move(visible_keys, key, direction) when direction in [:up, :down] do
    case to_key(key) do
      nil ->
        visible_keys

      atom_key ->
        case Enum.find_index(visible_keys, &(&1 == atom_key)) do
          nil ->
            visible_keys

          0 when direction == :up ->
            visible_keys

          idx when direction == :up ->
            swap(visible_keys, idx, idx - 1)

          idx when direction == :down and idx >= length(visible_keys) - 1 ->
            visible_keys

          idx when direction == :down ->
            swap(visible_keys, idx, idx + 1)
        end
    end
  end

  defp swap(list, i, j) do
    elem_i = Enum.at(list, i)
    elem_j = Enum.at(list, j)

    list
    |> List.replace_at(i, elem_j)
    |> List.replace_at(j, elem_i)
  end
end
