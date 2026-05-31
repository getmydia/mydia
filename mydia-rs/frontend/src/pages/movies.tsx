import { useState, useMemo, useEffect } from "react";
import { useQuery } from "urql";
import { MoviesDocument } from "../graphql/generated/graphql";
import type { MediaCategory, SortField, SortDirection } from "../graphql/generated/graphql";
import { PageHeader } from "../components/page-header";
import { Card } from "../components/card";
import { FilterBar } from "../components/filter-bar";

const MONITORED_FILTERS = [
  { value: "all", label: "All" },
  { value: "true", label: "Monitored" },
  { value: "false", label: "Unmonitored" },
];

const CATEGORY_FILTERS = [
  { value: "all", label: "All Categories" },
  { value: "STANDARD", label: "Standard" },
  { value: "ANIME", label: "Anime" },
  { value: "DOCUMENTARY", label: "Documentary" },
  { value: "STAND_UP", label: "Stand-Up" },
  { value: "REALITY", label: "Reality" },
];

const SORT_OPTIONS: { value: string; label: string; field: SortField; direction: SortDirection }[] = [
  { value: "title_asc", label: "Title A-Z", field: "TITLE", direction: "ASC" },
  { value: "title_desc", label: "Title Z-A", field: "TITLE", direction: "DESC" },
  { value: "year_desc", label: "Year (Newest)", field: "YEAR", direction: "DESC" },
  { value: "year_asc", label: "Year (Oldest)", field: "YEAR", direction: "ASC" },
  { value: "added_desc", label: "Added (Newest)", field: "ADDED_AT", direction: "DESC" },
  { value: "added_asc", label: "Added (Oldest)", field: "ADDED_AT", direction: "ASC" },
  { value: "rating_desc", label: "Rating (Highest)", field: "RATING", direction: "DESC" },
  { value: "rating_asc", label: "Rating (Lowest)", field: "RATING", direction: "ASC" },
];

const CATEGORY_LABELS: Record<string, string> = {
  STANDARD: "Standard",
  ANIME: "Anime",
  DOCUMENTARY: "Documentary",
  STAND_UP: "Stand-Up",
  REALITY: "Reality",
};

function formatSize(bytes: number | null | undefined): string {
  if (!bytes) return "";
  if (bytes >= 1_000_000_000) return `${(bytes / 1_000_000_000).toFixed(1)} GB`;
  if (bytes >= 1_000_000) return `${(bytes / 1_000_000).toFixed(1)} MB`;
  if (bytes >= 1_000) return `${(bytes / 1_000).toFixed(1)} KB`;
  return `${bytes} B`;
}

export function MoviesPage() {
  const [viewMode, setViewMode] = useState<"grid" | "list">("grid");
  const [monitoredFilter, setMonitoredFilter] = useState("all");
  const [categoryFilter, setCategoryFilter] = useState("all");
  const [searchTerm, setSearchTerm] = useState("");
  const [debouncedSearch, setDebouncedSearch] = useState("");
  const [sortKey, setSortKey] = useState("added_desc");

  useEffect(() => {
    const timer = setTimeout(() => setDebouncedSearch(searchTerm), 300);
    return () => clearTimeout(timer);
  }, [searchTerm]);

  const sortOpt = SORT_OPTIONS.find((s) => s.value === sortKey) ?? SORT_OPTIONS[4];
  const categoryVar = categoryFilter === "all" ? undefined : (categoryFilter as MediaCategory);

  const [result] = useQuery({
    query: MoviesDocument,
    variables: {
      first: 100,
      sort: { field: sortOpt.field, direction: sortOpt.direction },
      category: categoryVar,
    },
  });

  const edges = result.data?.movies?.edges ?? [];
  const totalCount = result.data?.movies?.totalCount ?? 0;
  const fetching = result.fetching;
  const error = result.error;

  const movies = useMemo(() => {
    let filtered = edges.map((e) => e.node);

    if (monitoredFilter === "true") {
      filtered = filtered.filter((m) => m.monitored);
    } else if (monitoredFilter === "false") {
      filtered = filtered.filter((m) => !m.monitored);
    }

    if (debouncedSearch) {
      const q = debouncedSearch.toLowerCase();
      filtered = filtered.filter(
        (m) =>
          m.title.toLowerCase().includes(q) ||
          (m.originalTitle ?? "").toLowerCase().includes(q) ||
          (m.overview ?? "").toLowerCase().includes(q)
      );
    }

    return filtered;
  }, [edges, monitoredFilter, debouncedSearch]);

  return (
    <div>
      <PageHeader
        title="Movies"
        subtitle={totalCount > 0 ? `${totalCount} movies in library` : "Browse your movie library"}
        actions={
          <div className="flex items-center gap-2">
            <select
              className="select select-bordered select-sm"
              value={sortKey}
              onChange={(e) => setSortKey(e.target.value)}
            >
              {SORT_OPTIONS.map((s) => (
                <option key={s.value} value={s.value}>
                  {s.label}
                </option>
              ))}
            </select>
            <div className="join">
              <button
                className={["join-item btn btn-sm", viewMode === "grid" ? "btn-active" : "btn-ghost"].join(" ")}
                onClick={() => setViewMode("grid")}
              >
                <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" strokeWidth={1.5} stroke="currentColor" className="w-4 h-4">
                  <path strokeLinecap="round" strokeLinejoin="round" d="M3.75 6A2.25 2.25 0 016 3.75h2.25A2.25 2.25 0 0110.5 6v2.25a2.25 2.25 0 01-2.25 2.25H6a2.25 2.25 0 01-2.25-2.25V6zM3.75 15.75A2.25 2.25 0 016 13.5h2.25a2.25 2.25 0 012.25 2.25V18a2.25 2.25 0 01-2.25 2.25H6A2.25 2.25 0 013.75 18v-2.25zM13.5 6a2.25 2.25 0 012.25-2.25H18A2.25 2.25 0 0120.25 6v2.25A2.25 2.25 0 0118 10.5h-2.25a2.25 2.25 0 01-2.25-2.25V6zM13.5 15.75a2.25 2.25 0 012.25-2.25H18a2.25 2.25 0 012.25 2.25V18A2.25 2.25 0 0118 20.25h-2.25A2.25 2.25 0 0113.5 18v-2.25z" />
                </svg>
              </button>
              <button
                className={["join-item btn btn-sm", viewMode === "list" ? "btn-active" : "btn-ghost"].join(" ")}
                onClick={() => setViewMode("list")}
              >
                <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" strokeWidth={1.5} stroke="currentColor" className="w-4 h-4">
                  <path strokeLinecap="round" strokeLinejoin="round" d="M8.25 6.75h12M8.25 12h12m-12 5.25h12M3.75 6.75h.007v.008H3.75V6.75zm.375 0a.375.375 0 11-.75 0 .375.375 0 01.75 0zM3.75 12h.007v.008H3.75V12zm.375 0a.375.375 0 11-.75 0 .375.375 0 01.75 0zm-.375 5.25h.007v.008H3.75v-.008zm.375 0a.375.375 0 11-.75 0 .375.375 0 01.75 0z" />
                </svg>
              </button>
            </div>
          </div>
        }
      />

      <div className="flex flex-col sm:flex-row sm:items-center gap-3 mb-4">
        <input
          type="text"
          placeholder="Search movies..."
          className="input input-bordered input-sm w-full sm:max-w-xs"
          value={searchTerm}
          onChange={(e) => setSearchTerm(e.target.value)}
        />
        <FilterBar current={monitoredFilter} options={MONITORED_FILTERS} onChange={setMonitoredFilter} />
        <FilterBar current={categoryFilter} options={CATEGORY_FILTERS} onChange={setCategoryFilter} />
      </div>

      {error && (
        <div className="alert alert-error mb-4">
          Failed to load movies.
        </div>
      )}

      {fetching && movies.length === 0 ? (
        <div className="flex justify-center py-16">
          <span className="loading loading-spinner loading-lg" />
        </div>
      ) : movies.length === 0 ? (
        <Card>
          <div className="text-center py-8">
            <p className="text-base-content/60 mb-4">
              {debouncedSearch ? "No movies match your search." : "No movies in your library yet."}
            </p>
            {!debouncedSearch && (
              <a href="/add/movie" className="btn btn-primary btn-sm">
                Add a Movie
              </a>
            )}
          </div>
        </Card>
      ) : viewMode === "grid" ? (
        <div className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6 gap-4">
          {movies.map((movie) => (
            <a
              key={movie.id}
              href={`/media/${movie.id}`}
              className="card bg-base-100 shadow hover:shadow-lg transition-shadow group"
            >
              <figure className="aspect-[2/3] bg-base-200 relative">
                {movie.artwork?.posterUrl ? (
                  <img
                    src={movie.artwork.posterUrl}
                    alt={movie.title}
                    className="w-full h-full object-cover"
                    loading="lazy"
                  />
                ) : (
                  <div className="flex items-center justify-center w-full h-full text-base-content/30">
                    <svg xmlns="http://www.w3.org/2000/svg" className="w-12 h-12" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                      <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={1} d="M15.75 10.5l4.72-4.72a.75.75 0 011.28.53v11.38a.75.75 0 01-1.28.53l-4.72-4.72M4.5 18.75h9a2.25 2.25 0 002.25-2.25v-9a2.25 2.25 0 00-2.25-2.25h-9A2.25 2.25 0 002.25 7.5v9a2.25 2.25 0 002.25 2.25z" />
                    </svg>
                  </div>
                )}
                <div className="absolute top-2 left-2 flex flex-col gap-1">
                  {movie.monitored && (
                    <span className="badge badge-primary badge-xs">Monitored</span>
                  )}
                  {movie.category && movie.category !== "STANDARD" && (
                    <span className="badge badge-secondary badge-xs">
                      {CATEGORY_LABELS[movie.category] ?? movie.category}
                    </span>
                  )}
                </div>
                {movie.progress?.percentage != null && movie.progress.percentage > 0 && (
                  <div className="absolute bottom-0 left-0 right-0 h-1 bg-base-300">
                    <div
                      className="h-full bg-primary"
                      style={{ width: `${Math.min(movie.progress.percentage, 100)}%` }}
                    />
                  </div>
                )}
              </figure>
              <div className="card-body p-3">
                <h3 className="text-sm font-semibold truncate">{movie.title}</h3>
                <div className="flex items-center justify-between text-xs text-base-content/60">
                  <span>{movie.year ?? "---"}</span>
                  <span>
                    {movie.files.length > 0 ? movie.files[0].resolution ?? "HD" : "No files"}
                  </span>
                </div>
              </div>
            </a>
          ))}
        </div>
      ) : (
        <div className="overflow-x-auto">
          <table className="table table-zebra">
            <thead>
              <tr>
                <th>Title</th>
                <th>Year</th>
                <th>Status</th>
                <th>Quality</th>
                <th>Rating</th>
                <th>Size</th>
              </tr>
            </thead>
            <tbody>
              {movies.map((movie) => (
                <tr key={movie.id} className="hover cursor-pointer" onClick={() => window.location.assign(`/media/${movie.id}`)}>
                  <td>
                    <div className="flex items-center gap-3">
                      <div className="avatar">
                        <div className="w-8 h-12 rounded">
                          {movie.artwork?.posterUrl ? (
                            <img src={movie.artwork.posterUrl} alt={movie.title} loading="lazy" />
                          ) : (
                            <div className="bg-base-200 w-full h-full flex items-center justify-center text-base-content/30 text-xs">
                              --
                            </div>
                          )}
                        </div>
                      </div>
                      <div>
                        <div className="font-semibold text-sm">{movie.title}</div>
                        {movie.originalTitle && movie.originalTitle !== movie.title && (
                          <div className="text-xs text-base-content/50">{movie.originalTitle}</div>
                        )}
                      </div>
                    </div>
                  </td>
                  <td className="text-sm">{movie.year ?? "---"}</td>
                  <td>
                    {movie.monitored ? (
                      <span className="badge badge-primary badge-sm">Monitored</span>
                    ) : (
                      <span className="badge badge-ghost badge-sm">Unmonitored</span>
                    )}
                  </td>
                  <td className="text-sm">
                    {movie.files.length > 0 ? movie.files[0].resolution ?? "?" : "---"}
                  </td>
                  <td className="text-sm">
                    {movie.rating != null ? `${Math.round(movie.rating * 10)}%` : "---"}
                  </td>
                  <td className="text-sm">
                    {movie.files.length > 0 ? formatSize(movie.files[0].size) : "---"}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
