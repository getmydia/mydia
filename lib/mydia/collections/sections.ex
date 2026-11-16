defmodule Mydia.Collections.Sections do
  @moduledoc """
  Sidebar section management for smart collections: pinning, unpinning,
  exclusivity eligibility, and exclusion queries for the built-in Movies and
  TV pages.
  """

  import Ecto.Query, warn: false

  alias Mydia.Accounts.{Scope, User}
  alias Mydia.Collections
  alias Mydia.Collections.{Collection, SmartRules}
  alias Mydia.Media.{MediaCategory, Stats}
  alias Mydia.Repo

  @doc """
  Returns the collections the user has pinned to their sidebar, in order.

  Pins are owner scoped. A shared collection pinned by its owner appears only
  in the owner's sidebar, which is what keeps a section from turning into a
  fixed section for everyone on the instance.
  """
  @spec list_pinned_sections(User.t()) :: [Collection.t()]
  def list_pinned_sections(%User{} = user) do
    from(c in Collection,
      where: c.user_id == ^user.id and not is_nil(c.pinned_position),
      order_by: [asc: c.pinned_position, asc: c.name]
    )
    |> Repo.all()
  end

  @doc """
  Returns the collections the user has pinned to their sidebar, in order, with
  the virtual `:item_count` field populated for `scope`.
  """
  @spec list_pinned_sections(User.t(), Scope.t()) :: [Collection.t()]
  def list_pinned_sections(%User{} = user, %Scope{} = scope) do
    user
    |> list_pinned_sections()
    |> Enum.map(&%{&1 | item_count: section_item_count(scope, &1)})
  end

  defp section_item_count(scope, %Collection{type: "smart", smart_rules: rules}) do
    case SmartRules.query(rules || "{}") do
      {:ok, query} ->
        try do
          Stats.count_media_items(scope, base_query: query)
        rescue
          Ecto.Query.CastError -> 0
          Ecto.QueryError -> 0
        end

      {:error, _} ->
        0
    end
  end

  defp section_item_count(scope, %Collection{} = collection) do
    Collections.item_count(scope, collection)
  end

  @doc """
  Returns the category names that the user's exclusive sections have claimed
  away from the built-in Movies and TV pages.

  Derived from the rules on every read rather than stored, so it cannot drift
  from the rules that produced it. Returns `[]` for anything it cannot read
  with certainty, including malformed JSON, because the caller is the sidebar
  and the library pages: failing open is the only safe direction.
  """
  @spec claimed_categories(User.t() | [Collection.t()]) :: [binary()]
  def claimed_categories(%User{} = user) do
    user |> list_pinned_sections() |> claimed_categories()
  end

  def claimed_categories(sections) when is_list(sections) do
    sections
    |> Enum.filter(& &1.exclusive)
    |> pinned_categories()
  end

  @doc """
  Returns the Ecto queries that the user's exclusive sections have claimed
  away from the built-in Movies and TV pages.

  Derived from each section's smart rules on every read rather than stored,
  so it cannot drift from the rules that produced it. Returns `[]` for any
  section whose rules are empty or malformed so the sidebar and library pages
  fail open.
  """
  @spec excluded_queries(User.t() | [Collection.t()]) :: [Ecto.Query.t()]
  def excluded_queries(%User{} = user) do
    user |> list_pinned_sections() |> excluded_queries()
  end

  def excluded_queries(sections) when is_list(sections) do
    sections
    |> Enum.filter(& &1.exclusive)
    |> Enum.flat_map(&section_exclusion_query/1)
  end

  @doc """
  Returns the category names covered by every pinned section, whether or not
  that section is exclusive.
  """
  @spec pinned_categories([Collection.t()]) :: [binary()]
  def pinned_categories(sections) when is_list(sections) do
    sections
    |> Enum.flat_map(&section_categories/1)
    |> Enum.uniq()
  end

  @doc """
  Returns true when a collection can be made exclusive to keep its items out of
  the built-in Movies and TV pages.

  Any smart collection with at least one valid condition qualifies. Manual
  collections and smart collections with empty or unreadable rules return false.
  """
  @spec exclusive_eligible?(Collection.t()) :: boolean()
  def exclusive_eligible?(%Collection{type: "smart", smart_rules: rules}) when is_binary(rules) do
    section_exclusion_query(%Collection{type: "smart", smart_rules: rules}) != []
  end

  def exclusive_eligible?(%Collection{}), do: false

  @doc """
  Pins a collection to the user's sidebar, appending it after existing sections.
  """
  @spec pin_section(User.t(), Collection.t(), keyword()) ::
          {:ok, Collection.t()}
          | {:error, Ecto.Changeset.t() | :unauthorized | :system_collection | :not_smart}
  def pin_section(user, collection, opts \\ [])

  def pin_section(%User{} = _user, %Collection{type: "manual"} = _collection, _opts) do
    {:error, :not_smart}
  end

  def pin_section(%User{} = user, %Collection{type: "smart"} = collection, opts) do
    next_position =
      user
      |> list_pinned_sections()
      |> Enum.map(& &1.pinned_position)
      |> Enum.max(fn -> -1 end)
      |> Kernel.+(1)

    exclusive = Keyword.get(opts, :exclusive, false) and exclusive_eligible?(collection)

    attrs = %{pinned_position: next_position, exclusive: exclusive}

    attrs =
      case Keyword.fetch(opts, :sidebar_icon) do
        {:ok, icon} -> Map.put(attrs, :sidebar_icon, icon)
        :error -> attrs
      end

    Collections.update_collection(user, collection, attrs)
  end

  @doc """
  Removes a collection from the sidebar. The collection itself is kept.
  """
  @spec unpin_section(User.t(), Collection.t()) ::
          {:ok, Collection.t()} | {:error, Ecto.Changeset.t()}
  def unpin_section(%User{} = user, %Collection{} = collection) do
    Collections.update_collection(user, collection, %{
      pinned_position: nil,
      exclusive: false
    })
  end

  defp section_exclusion_query(%Collection{type: "smart", smart_rules: rules})
       when is_binary(rules) do
    case Jason.decode(rules) do
      {:ok, %{"conditions" => [_ | _] = conditions} = decoded} ->
        if Enum.all?(conditions, &SmartRules.supported_condition?/1) do
          case SmartRules.query(decoded) do
            {:ok, query} -> [query]
            {:error, _} -> []
          end
        else
          []
        end

      _ ->
        []
    end
  end

  defp section_exclusion_query(_collection), do: []

  defp section_categories(%Collection{type: "smart", smart_rules: rules})
       when is_binary(rules) do
    case Jason.decode(rules) do
      {:ok, %{"conditions" => [condition]}} -> condition_categories(condition)
      _ -> []
    end
  end

  defp section_categories(_collection), do: []

  defp condition_categories(%{
         "field" => "category",
         "operator" => "in",
         "value" => values
       })
       when is_list(values) do
    known = Enum.map(MediaCategory.all(), &Atom.to_string/1)
    Enum.filter(values, &(&1 in known))
  end

  defp condition_categories(_condition), do: []
end
