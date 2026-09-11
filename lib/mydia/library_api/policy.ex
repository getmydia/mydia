defmodule Mydia.LibraryApi.Policy do
  @moduledoc """
  The single place that decides who may do what on the Library API.

  v1 admits admins only. When other roles are admitted, relax this module and
  `MydiaWeb.Plugs.LibraryApiAuth`'s 403 fence; no schema field changes, because
  every field already declares the action it needs.
  """

  alias Mydia.LibraryApi.Principal

  @actions [
    :read_library,
    :read_downloads,
    :read_events,
    :manage_library,
    :search,
    :manage_downloads
  ]

  @doc "Every action a Library API field may declare."
  @spec actions() :: [atom()]
  def actions, do: @actions

  @doc "Whether `principal` may perform `action`. Fails closed."
  @spec permit?(Principal.t() | nil, atom()) :: boolean()
  def permit?(%Principal{role: "admin"}, action) when action in @actions, do: true
  def permit?(_principal, _action), do: false
end
