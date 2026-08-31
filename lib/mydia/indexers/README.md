# Indexers

## category_mapping.ex is Torznab protocol, not a media vertical

`lib/mydia/indexers/category_mapping.ex` has around 14 references to music, books
and adult, and reads like part of those verticals. It is not. It maps
Torznab/Newznab protocol categories, an external standard that still defines
Audio (3000), XXX (6000) and Books (7000) regardless of what Mydia stores.

Its `@audio_*`, `@xxx_*` and `@books_*` module attributes feed three things that
parse and render what third-party indexers publish: `category_name/1` (IDs to
display names like `"XXX/DVD"`), `category_id_for_name/1` (Cardigann category
names to IDs), and the full category list near the end of the module. Deleting
those constants breaks indexer capability parsing for every user.

Only the clauses whose argument is a Mydia library type are dead when the
verticals go: `categories_for_type(:music | :books | :adult)` and
`parent_category(:music | :books | :adult)`.

`type_for_category/1` is the interesting one. It feeds auto-detection in
`search_live/index.ex:386`, which treats `:other` as "no type detected, show the
manual library picker". Letting 3000, 6000 and 7000 fall through to `:other`
routes those results to the picker instead of auto-filing them. Nothing leaks and
nothing is hidden; the operator just picks a library. Its tests should be changed
to assert `:other` rather than deleted.

## Req carries a manual Cookie header across redirects

Req forwards a manually supplied `Cookie` header along a redirect, including to a
different host. It special-cases only the `authorization` header, which is
dropped on untrusted cross-host redirects and tunable via
`:redirect_trusted_hosts`. Headers you set yourself, `Cookie` included, are
carried to the redirect target unchanged.

Verified empirically on 2026-08-29 with two Bypass servers on different ports:
server A returned a 302 to server B, and B received `session=secret` verbatim. Req
has no cookie jar and no origin model, so do not assume it scopes cookies.

Any code attaching a session cookie as a raw header and letting Req follow
redirects hands that credential to whatever host the `Location` names. When the
redirect source is remote content such as a tracker, a mirror or a scraped site,
that is attacker-triggerable rather than accidental.

When attaching credentials as a raw header, either set `redirect: false` and
handle hops yourself with a per-hop origin check, or accept that the credential
goes wherever the response points. The Cardigann search engine takes the first
option: `attach_cookies/3` in `lib/mydia/indexers/cardigann_search_engine.ex`
sets `redirect: false` whenever it attaches a `Cookie`, and an unfollowed 3xx
falls through to the existing failover. Trusted-origin scoping for absolute paths
and mirror failover is tracked in issue #602.
