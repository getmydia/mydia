defmodule Mydia.Events.Visibility do
  @moduledoc """
  Decides which events a viewer is allowed to read.

  The rule lives here once, as data, and is compiled into the two forms the
  application needs: an Ecto `where` clause for paginated queries (`scope/2`)
  and a boolean check for events arriving over PubSub (`visible?/2`). A single
  source is the point. `MydiaWeb.ActivityLive.Index` already maintains its
  live-insert check as a hand-written mirror of its SQL filter, and that mirror
  is exactly what drifts.
  """

  import Ecto.Query, warn: false

  alias Mydia.Accounts.User
  alias Mydia.Events.Event

  defmodule Policy do
    @moduledoc """
    A restricted viewer's allowlist.

    `types` are visible whoever caused them. `own_types` are visible only when
    the event's actor is the viewer. `categories` names the categories those
    types are recorded under, so the UI can drop filter chips that could never
    match. It is declared rather than derived: the type-to-category mapping
    lives in the `Mydia.Events` writer functions, not in the type registry.
    """

    defstruct types: [], own_types: [], categories: []

    @type t :: %__MODULE__{
            types: [String.t()],
            own_types: [String.t()],
            categories: [String.t()]
          }
  end

  @doc """
  Returns the visibility policy for a viewer.

  `:unrestricted` for admin, user and readonly; the guest policy for a guest;
  `:none` when there is no viewer.
  """
  @spec policy_for(User.t() | nil) :: :unrestricted | :none | Policy.t()
  def policy_for(nil), do: :none
  def policy_for(%User{role: "guest"}), do: guest_policy()
  def policy_for(%User{}), do: :unrestricted

  # A function rather than a module attribute: this compiler rejects a
  # `@guest_policy %Policy{...}` module attribute that references the nested
  # Policy struct, because the attribute is evaluated in the same compilation
  # context that is still defining that struct. A function body runs after
  # both modules have finished compiling, so it has no such restriction.
  defp guest_policy do
    %Policy{
      types: ["media_item.added", "media_item.removed"],
      own_types: ["playback.started", "playback.finished", "playback.unwatched"],
      categories: ["media", "playback"]
    }
  end

  @doc """
  Restricts an event query to the rows the viewer may read.

  Applied before pagination so `:limit` and `:offset` stay correct.
  """
  @spec scope(Ecto.Queryable.t(), User.t() | nil) :: Ecto.Query.t()
  def scope(query, user) do
    case policy_for(user) do
      :unrestricted ->
        query

      :none ->
        # An explicit contradiction rather than an `actor_id == ^nil`
        # comparison. The latter compiles to `= NULL`, which is never true on
        # either adapter, so it would give the right answer through a mechanism
        # no reader can see.
        where(query, [_e], fragment("1 = 0"))

      %Policy{types: types, own_types: own_types} ->
        viewer_id = user.id

        where(
          query,
          [e],
          e.type in ^types or
            (e.type in ^own_types and e.actor_type == ^:user and e.actor_id == ^viewer_id)
        )
    end
  end

  @doc """
  Whether a single in-memory event is visible to the viewer.

  The PubSub counterpart of `scope/2`. Both read the same policy.
  """
  @spec visible?(Event.t(), User.t() | nil) :: boolean()
  def visible?(%Event{} = event, user) do
    case policy_for(user) do
      :unrestricted -> true
      :none -> false
      %Policy{} = policy -> matches?(event, policy, user.id)
    end
  end

  @doc """
  The event categories a viewer can encounter, or `:all` when unrestricted.

  Consumers use this to drop filter controls that could never match a row.
  """
  @spec visible_categories(User.t() | nil) :: :all | [String.t()]
  def visible_categories(user) do
    case policy_for(user) do
      :unrestricted -> :all
      :none -> []
      %Policy{categories: categories} -> categories
    end
  end

  defp matches?(%Event{type: type} = event, %Policy{} = policy, viewer_id) do
    type in policy.types or
      (type in policy.own_types and event.actor_type == :user and event.actor_id == viewer_id)
  end
end
