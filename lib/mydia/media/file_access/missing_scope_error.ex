defmodule Mydia.Media.FileAccess.MissingScopeError do
  @moduledoc """
  Reported, never raised, when `Mydia.Media.FileAccess` authorizes a media
  file for a caller that carries no `Mydia.Accounts.Scope`.

  That only happens when an auth boundary forgot to assign one. The request is
  still denied (fail closed), but for an unrestricted account the denial is a
  404 indistinguishable from a missing file, so the gap is reported through
  `Mydia.CrashReporter` where an operator can see it.
  """

  defexception message:
                 "media file authorization ran without a current_scope; " <>
                   "an auth boundary did not assign one"
end
