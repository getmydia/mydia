defmodule Mydia.Plugins.Capabilities do
  @moduledoc """
  Compares a plugin's **requested** capability set against its **granted** one.

  A manifest only declares what a plugin wants; `granted_capabilities` records
  what the operator actually approved (see `Mydia.Plugins.Plugin`). The two drift
  apart whenever a manifest is revised after approval: `Mydia.Plugins` re-stores
  the revised manifest but deliberately never widens the grant, so the plugin
  keeps running on the older, narrower set and every call into something newly
  requested comes back `Denied`.

  This module is the single place that answers "does the grant still cover what
  the manifest asks for?", so the admin UI, the activation warning, and the tests
  all agree on what counts as a widened request.

  ## Capability shapes

  A capability set is a map of `class => payload`, and the taxonomy uses three
  payload shapes, each compared on its own terms:

    * **Value lists** — `events:subscribe`, `net:http`, `data:read`,
      `surfaces:write`. Every element is separately meaningful (an event type, a
      hostname, a read namespace, a write surface) and the host gates on the
      *element*, not on the class. A new element is therefore a new request even
      though the class itself was already granted.
    * **Flags** — `state:kv`, `users:connections`, `schedule:interval` declare an
      empty list; only the presence of the class matters.
    * **Anything else** — an opaque payload is compared by equality, and any
      change counts as a new request. Nothing in the v1 taxonomy uses this shape;
      treating a payload we cannot decompose as widened is the fail-closed
      default.

  Values that are granted but no longer requested are **not** reported. A
  narrowed manifest leaves the operator holding a grant broader than the plugin
  needs, which is a revoke decision, not a re-approval one.
  """

  @type set :: %{optional(String.t()) => term()}

  @doc """
  Returns the subset of `requested` that `granted` does not cover, as a
  capability set of `class => [uncovered values]`.

  An entirely ungranted class maps to its full requested payload; a class whose
  payload widened maps to just the new values. `%{}` means the grant still covers
  everything the manifest asks for.
  """
  @spec ungranted(set(), set()) :: set()
  def ungranted(requested, granted) when is_map(requested) and is_map(granted) do
    requested
    |> Enum.flat_map(fn {class, payload} ->
      case Map.fetch(granted, class) do
        :error -> [{class, normalize(payload)}]
        {:ok, granted_payload} -> payload_diff(class, payload, granted_payload)
      end
    end)
    |> Map.new()
  end

  @doc "True when `granted` covers every class and value in `requested`."
  @spec covered?(set(), set()) :: boolean()
  def covered?(requested, granted), do: ungranted(requested, granted) == %{}

  @doc """
  Renders a capability set as a compact, log-friendly string
  (`net:http [api.example.com], state:kv`). Host-owned prose for the admin UI
  lives in `MydiaWeb.AdminPluginsLive.Components.capability_label/2` instead.
  """
  @spec summary(set()) :: String.t()
  def summary(set) when map_size(set) == 0, do: "(none)"

  def summary(set) do
    set
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join(", ", fn {class, payload} ->
      case normalize(payload) do
        [] -> class
        values -> "#{class} [#{Enum.map_join(values, ", ", &render_value/1)}]"
      end
    end)
  end

  defp payload_diff(class, payload, granted_payload) do
    case normalize(payload) -- normalize(granted_payload) do
      [] -> []
      extra -> [{class, extra}]
    end
  end

  # A flag capability declares `[]` (or nothing at all); a scoped one declares a
  # list of values; anything else is one opaque value compared by equality.
  defp normalize(nil), do: []
  defp normalize(payload) when is_list(payload), do: payload
  defp normalize(payload), do: [payload]

  defp render_value(value) when is_binary(value), do: value
  defp render_value(value), do: inspect(value)
end
