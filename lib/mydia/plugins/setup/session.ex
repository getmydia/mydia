defmodule Mydia.Plugins.Setup.Session do
  @moduledoc """
  One operator's walk through a plugin instance's setup screens.

  `screen` is the last screen the guest returned (see
  `Mydia.Plugins.invoke_setup/3` for its shape). `state_json` is the guest's
  opaque state, handed back on the next call. `pending_endpoints` lists the
  endpoints this session approved, so cancelling can take them back.
  """

  @type status :: :active | :done | :cancelled

  @type t :: %__MODULE__{
          slug: String.t(),
          instance_id: binary(),
          new_instance?: boolean(),
          step: String.t(),
          state_json: String.t(),
          screen: map() | nil,
          pending_endpoints: [map()],
          error: String.t() | nil,
          status: status()
        }

  @enforce_keys [:slug, :instance_id]
  defstruct [
    :slug,
    :instance_id,
    :screen,
    :error,
    new_instance?: false,
    step: "start",
    state_json: "{}",
    pending_endpoints: [],
    status: :active
  ]
end
