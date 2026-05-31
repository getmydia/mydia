import { useState, useCallback, useMemo } from "react";
import { useQuery, useMutation } from "urql";
import { DiscoverDocument, AddToLibraryDocument } from "../graphql/generated/graphql";
import type { MediaType, DiscoverQuery } from "../graphql/generated/graphql";
import { PageHeader } from "../components/page-header";
import { Card } from "../components/card";
import { Button } from "../components/button";

type DiscoverItem = DiscoverQuery['discover']['results'][number];

const MOVIE_CATEGORIES = [
  { key: "trending", label: "Trending" },
  { key: "popular", label: "Popular" },
  { key: "upcoming", label: "Upcoming" },
  { key: "now_playing", label: "Now Playing" },
] as const;

const TV_CATEGORIES = [
  { key: "trending", label: "Trending" },
  { key: "popular", label: "Popular" },
  { key: "on_the_air", label: "On The Air" },
  { key: "airing_today", label: "Airing Today" },
] as const;

const MEDIA_TYPE_LABELS: Record<string, string> = {
  MOVIE: "Movies",
  TV_SHOW: "TV Shows",
};

function posterSrc(posterUrl: string | null | undefined): string | null {
  if (!posterUrl) return null;
  return posterUrl;
}

export function DiscoverPage() {
  const [mediaType, setMediaType] = useState<MediaType>("MOVIE" as MediaType);
  const [category, setCategory] = useState("trending");
  const [page, setPage] = useState(1);
  const [allItems, setAllItems] = useState<DiscoverItem[]>([]);
  const [addingId, setAddingId] = useState<number | null>(null);
  const [locallyAdded, setLocallyAdded] = useState<Set<number>>(new Set());

  const [{ data, fetching, error }] = useQuery({
    query: DiscoverDocument,
    variables: { category, mediaType, page },
  });

  const [, addToLibrary] = useMutation(AddToLibraryDocument);

  const categories =
    mediaType === ("TV_SHOW" as MediaType) ? TV_CATEGORIES : MOVIE_CATEGORIES;

  const results = data?.discover?.results ?? [];
  const pageInfo = data?.discover;
  const hasMore = pageInfo ? pageInfo.page < pageInfo.totalPages : false;

  // When data changes, merge into allItems for "load more" support.
  // When page is 1 (reset), use results directly.
  const displayItems = useMemo(() => {
    if (page === 1 || fetching) return results;
    // Deduplicate on tmdbId
    const seen = new Set(allItems.map((i) => i.tmdbId));
    const newItems = results.filter((i) => !seen.has(i.tmdbId));
    return [...allItems, ...newItems];
  }, [results, allItems, page, fetching]);

  // Sync allItems when page 1
  const effectiveItems = page === 1 && !fetching ? results : displayItems;

  const handleMediaTypeChange = useCallback(
    (mt: MediaType) => {
      setMediaType(mt);
      setCategory("trending");
      setPage(1);
      setAllItems([]);
      setLocallyAdded(new Set());
    },
    [],
  );

  const handleCategoryChange = useCallback(
    (cat: string) => {
      setCategory(cat);
      setPage(1);
      setAllItems([]);
    },
    [],
  );

  const handleLoadMore = useCallback(() => {
    const next = page + 1;
    setPage(next);
    setAllItems(effectiveItems);
  }, [page, effectiveItems]);

  const handleAddToLibrary = useCallback(
    async (item: DiscoverItem) => {
      setAddingId(item.tmdbId);
      const typeStr = item.type === ("TV_SHOW" as MediaType) ? "tv_show" : "movie";
      const res = await addToLibrary({
        input: {
          mediaType: typeStr,
          title: item.title,
          tmdbId: item.tmdbId,
          tvdbId: null,
          qualityProfileId: null,
          monitored: true,
          monitoringPreset: null,
        },
      });
      setAddingId(null);
      if (res.error) {
        console.error("Failed to add to library:", res.error.message);
      } else {
        setLocallyAdded((prev) => new Set(prev).add(item.tmdbId));
      }
    },
    [addToLibrary],
  );

  const isInLibrary = useCallback(
    (item: DiscoverItem) => item.inLibrary || locallyAdded.has(item.tmdbId),
    [locallyAdded],
  );

  return (
    <div>
      <PageHeader
        title="Discover"
        subtitle="Discover new content to add to your library"
      />

      <div className="flex flex-col gap-4 mb-6">
        {/* Media type toggle */}
        <div className="join">
          {(["MOVIE", "TV_SHOW"] as MediaType[]).map((mt) => (
            <button
              key={mt}
              className={[
                "join-item btn btn-sm",
                mediaType === mt ? "btn-primary" : "btn-ghost",
              ].join(" ")}
              onClick={() => handleMediaTypeChange(mt)}
            >
              {MEDIA_TYPE_LABELS[mt] ?? mt}
            </button>
          ))}
        </div>

        {/* Category tabs */}
        <div className="tabs tabs-boxed bg-base-200/50">
          {categories.map((cat) => (
            <button
              key={cat.key}
              className={[
                "tab",
                category === cat.key ? "tab-active" : "",
              ].join(" ")}
              onClick={() => handleCategoryChange(cat.key)}
            >
              {cat.label}
            </button>
          ))}
        </div>
      </div>

      {error && (
        <div className="alert alert-error mb-4">
          Failed to load discoveries.
        </div>
      )}

      {fetching && page === 1 ? (
        <div className="flex justify-center py-16">
          <span className="loading loading-spinner loading-lg" />
        </div>
      ) : effectiveItems.length === 0 ? (
        <Card>
          <p className="text-base-content/60">
            No results found. Try a different category or media type.
          </p>
        </Card>
      ) : (
        <>
          <div className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 gap-4">
            {effectiveItems.map((item) => (
              <div
                key={item.tmdbId}
                className="card bg-base-100 shadow hover:shadow-lg transition-shadow"
              >
                <figure className="aspect-[2/3] bg-base-200 relative">
                  {posterSrc(item.posterUrl) ? (
                    <img
                      src={posterSrc(item.posterUrl)!}
                      alt={item.title}
                      className="w-full h-full object-cover"
                      loading="lazy"
                    />
                  ) : (
                    <div className="flex items-center justify-center w-full h-full text-base-content/30">
                      <svg
                        xmlns="http://www.w3.org/2000/svg"
                        className="w-12 h-12"
                        fill="none"
                        viewBox="0 0 24 24"
                        stroke="currentColor"
                      >
                        <path
                          strokeLinecap="round"
                          strokeLinejoin="round"
                          strokeWidth={1}
                          d="M15.75 10.5l4.72-4.72a.75.75 0 011.28.53v11.38a.75.75 0 01-1.28.53l-4.72-4.72M4.5 18.75h9a2.25 2.25 0 002.25-2.25v-9a2.25 2.25 0 00-2.25-2.25h-9A2.25 2.25 0 002.25 7.5v9a2.25 2.25 0 002.25 2.25z"
                        />
                      </svg>
                    </div>
                  )}

                  {/* Vote average badge */}
                  {item.voteAverage != null && item.voteAverage > 0 && (
                    <div className="absolute top-2 right-2 badge badge-sm badge-primary">
                      {item.voteAverage.toFixed(0)}%
                    </div>
                  )}

                  {/* In-library indicator */}
                  {isInLibrary(item) && (
                    <div className="absolute top-2 left-2 badge badge-sm badge-success">
                      In Library
                    </div>
                  )}
                </figure>

                <div className="card-body p-3 gap-1">
                  <h3 className="text-sm font-semibold truncate">{item.title}</h3>
                  <p className="text-xs text-base-content/60">
                    {item.year ?? "---"}
                    {item.type && ` \u00b7 ${item.type === ("TV_SHOW" as MediaType) ? "TV" : "Movie"}`}
                  </p>

                  <div className="mt-1">
                    {isInLibrary(item) ? (
                      <a
                        href={`/media/${item.tmdbId}`}
                        className="btn btn-ghost btn-xs w-full text-success"
                      >
                        In Your Library
                      </a>
                    ) : (
                      <Button
                        variant="primary"
                        size="xs"
                        loading={addingId === item.tmdbId}
                        onClick={(e) => {
                          e.preventDefault();
                          handleAddToLibrary(item);
                        }}
                        className="w-full"
                      >
                        + Add to Library
                      </Button>
                    )}
                  </div>
                </div>
              </div>
            ))}
          </div>

          {/* Load more */}
          {hasMore && (
            <div className="flex justify-center py-8">
              <Button
                variant="ghost"
                onClick={handleLoadMore}
                loading={fetching && page > 1}
              >
                Load More
              </Button>
            </div>
          )}
        </>
      )}
    </div>
  );
}
