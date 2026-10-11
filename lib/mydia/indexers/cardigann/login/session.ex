defmodule Mydia.Indexers.Cardigann.Login.Session do
  @moduledoc "An established Cardigann login: the cookies to send with searches."

  @type method :: :none | :cookie | :get | :post | :form
  @type t :: %__MODULE__{cookies: [String.t()], method: method(), expires_at: DateTime.t() | nil}

  defstruct cookies: [], method: :none, expires_at: nil
end
