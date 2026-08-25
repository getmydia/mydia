defmodule Mydia.Events.Visibility.Policy do
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
