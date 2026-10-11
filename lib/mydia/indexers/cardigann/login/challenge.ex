defmodule Mydia.Indexers.Cardigann.Login.Challenge do
  @moduledoc """
  A form login paused for a person: the captcha image and the fields to fill.

  `pending` is the form strategy's state (cookie jar, scraped fields, submit URL).
  It lives only in the LiveView process that asked for it and is never persisted.
  """

  @type t :: %__MODULE__{
          definition_id: String.t(),
          fields: [String.t()],
          image: binary() | nil,
          image_type: String.t() | nil,
          pending: map()
        }

  @derive {Inspect, except: [:pending, :image]}
  @enforce_keys [:definition_id, :fields, :pending]
  defstruct [:definition_id, :image, :image_type, fields: [], pending: %{}]
end
