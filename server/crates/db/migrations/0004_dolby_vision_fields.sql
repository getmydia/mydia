-- Raw Dolby Vision fields alongside the existing hdr_format display string.
-- Mirrors Mydia.Library.Hdr's dv_profile/bl_compat_id: profile (5, 7, 8, ...)
-- and the DOVI base-layer compatibility id (1 = HDR10 base, 4 = HLG base,
-- 0/2 = none). hdr_format alone cannot carry this: every Dolby Vision
-- variant, including profile 5, displays as "Dolby Vision", so a client
-- wanting the profile distinction reads these two columns instead.
--
-- hdr_format here (media_files.hdr_format, 0002_library.sql) stays free
-- text, unlike the Elixir app's media_files.hdr_format, which the
-- canonicalize_hdr_format migration turned into a strict Ecto.Enum of
-- :hdr10 / :hdr10_plus / :hlg. That is only safe because mydia-server runs
-- its own standalone SQLite database rather than sharing the Elixir one; a
-- future unification of the two storage layers must not let this crate go
-- on writing display strings like "HDR10" into a column Elixir would then
-- fail to decode.
ALTER TABLE media_files ADD COLUMN dolby_vision_profile INTEGER;
ALTER TABLE media_files ADD COLUMN dolby_vision_bl_compat_id INTEGER;
