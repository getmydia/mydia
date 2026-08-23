-- Raw Dolby Vision fields alongside the existing hdr_format display string.
-- Mirrors Mydia.Library.Hdr's dv_profile/bl_compat_id: profile (5, 7, 8, ...)
-- and the DOVI base-layer compatibility id (1 = HDR10 base, 4 = HLG base,
-- 0/2 = none). hdr_format alone cannot carry this: every Dolby Vision
-- variant, including profile 5, displays as "Dolby Vision", so a client
-- wanting the profile distinction reads these two columns instead.
ALTER TABLE media_files ADD COLUMN dolby_vision_profile INTEGER;
ALTER TABLE media_files ADD COLUMN dolby_vision_bl_compat_id INTEGER;
