defmodule Mydia.Collections.Preset do
  @moduledoc """
  One entry in the preset collection catalog.

  A preset is a named bundle of smart rules. Adding one stamps `rules` onto an
  ordinary smart collection, which then has no back-reference to the preset it
  came from: it is fully editable and deletable like any hand-built collection.

  `icon` is constrained to `Mydia.Collections.Collection.valid_sidebar_icons/0`.
  That is not cosmetic. Preset icons are chosen at runtime from data in
  `lib/mydia/`, which sits outside the `@source` globs in `app.css`, so Tailwind
  never emits their CSS unless the name is safelisted. Reusing the sidebar
  allowlist inherits both the safelist and its drift test.
  """

  @enforce_keys [:key, :name, :description, :icon, :group, :rules]
  defstruct [:key, :name, :description, :icon, :group, :rules]

  @type t :: %__MODULE__{
          key: String.t(),
          name: String.t(),
          description: String.t(),
          icon: String.t(),
          group: String.t(),
          rules: map()
        }
end
