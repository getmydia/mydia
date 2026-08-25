defmodule Mydia.Media.Restrictions do
  @moduledoc """
  Turns a `Mydia.Accounts.Scope` into Ecto query predicates.

  Both dimensions are filtered on real indexed columns rather than on the
  metadata JSON blob, so the same query runs on SQLite and PostgreSQL without
  adapter branching.

  An item must satisfy every dimension the scope sets. Category and rating are
  combined with AND, not OR.
  """

  import Ecto.Query

  alias Mydia.Accounts.Scope
  alias Mydia.Media.MediaItem

  @doc """
  Applies a scope's restrictions to a query rooted at `MediaItem`.
  """
  @spec apply(Ecto.Query.t() | module(), Scope.t()) :: Ecto.Query.t()
  def apply(query, %Scope{allowed_categories: nil, max_content_age: nil}), do: query

  def apply(query, %Scope{} = scope) do
    query
    |> apply_categories(scope.allowed_categories)
    |> apply_max_age(scope.max_content_age)
  end

  @doc """
  Applies a scope's restrictions to a query rooted at `Episode`, by joining the
  parent show.

  Category and rating are properties of the series. `episodes` carries neither
  column, so an episode is visible exactly when its show is.
  """
  @spec apply_to_episodes(Ecto.Query.t() | module(), Scope.t()) :: Ecto.Query.t()
  def apply_to_episodes(query, %Scope{allowed_categories: nil, max_content_age: nil}), do: query

  def apply_to_episodes(query, %Scope{} = scope) do
    from(e in query,
      join: m in MediaItem,
      on: m.id == e.media_item_id,
      where: ^dynamic_conditions(scope)
    )
  end

  @doc """
  True when a loaded media item is visible under this scope.

  For call sites that already hold the struct and would otherwise re-query.
  Kept consistent with `apply/2` by covering both in the same test file.
  """
  @spec visible?(MediaItem.t(), Scope.t()) :: boolean()
  def visible?(_item, %Scope{allowed_categories: nil, max_content_age: nil}), do: true

  def visible?(%MediaItem{} = item, %Scope{} = scope) do
    category_ok?(item.category, scope.allowed_categories) and
      age_ok?(item.content_rating_age, scope.max_content_age)
  end

  defp apply_categories(query, nil), do: query

  # An empty list means "no category limit", the same as nil. Scope.for_user/1
  # already normalizes [] to nil, so this is not reachable through that path
  # today, but a hand-built %Scope{allowed_categories: []} must not fall
  # through to `category in []`, which would deny every item instead of none.
  defp apply_categories(query, []), do: query

  # A NULL category is unclassified rather than permitted. `in` already excludes
  # NULL in SQL, so this needs no extra clause, but the behaviour is load
  # bearing and is covered by a test.
  defp apply_categories(query, categories) do
    from(m in query, where: m.category in ^categories)
  end

  defp apply_max_age(query, nil), do: query

  # `is_nil` is excluded on purpose. An unrated title under an active limit is
  # hidden, because a missing rating is not evidence that a title is suitable.
  defp apply_max_age(query, max_age) do
    from(m in query, where: not is_nil(m.content_rating_age) and m.content_rating_age <= ^max_age)
  end

  # The episode join needs the same predicates against the joined binding, which
  # the query-macro forms above cannot express directly.
  defp dynamic_conditions(%Scope{} = scope) do
    conditions = dynamic(true)

    conditions =
      case scope.allowed_categories do
        nil -> conditions
        [] -> conditions
        categories -> dynamic([_e, m], ^conditions and m.category in ^categories)
      end

    case scope.max_content_age do
      nil ->
        conditions

      max_age ->
        dynamic(
          [_e, m],
          ^conditions and not is_nil(m.content_rating_age) and m.content_rating_age <= ^max_age
        )
    end
  end

  defp category_ok?(_category, nil), do: true
  defp category_ok?(_category, []), do: true
  defp category_ok?(category, categories), do: category in categories

  defp age_ok?(_age, nil), do: true
  defp age_ok?(nil, _max_age), do: false
  defp age_ok?(age, max_age), do: age <= max_age
end
