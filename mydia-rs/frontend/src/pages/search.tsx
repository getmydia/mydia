import { useState, useCallback, useRef } from "react";
import { useQuery } from "urql";
import { SearchMediaDocument } from "../graphql/generated/graphql";
import { PageHeader } from "../components/page-header";

export function SearchPage() {
  const [query, setQuery] = useState("");
  const [searchTerm, setSearchTerm] = useState("");
  const inputRef = useRef<HTMLInputElement>(null);

  const [{ data, fetching, error }] = useQuery({
    query: SearchMediaDocument,
    variables: { query: searchTerm, first: 20 },
    pause: searchTerm.length === 0,
  });

  const results = data?.search?.results ?? [];
  const totalCount = data?.search?.totalCount ?? 0;

  const handleSearch = useCallback(
    (e: React.FormEvent) => {
      e.preventDefault();
      setSearchTerm(query.trim());
    },
    [query],
  );

  return (
    <div>
      <PageHeader title="Search" subtitle="Find movies and TV shows" />

      <form onSubmit={handleSearch} className="mb-6">
        <div className="join w-full">
          <input
            ref={inputRef}
            type="text"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="Search by title..."
            className="input input-bordered join-item flex-1"
          />
          <button type="submit" className="btn btn-primary join-item" disabled={fetching}>
            {fetching ? (
              <span className="loading loading-spinner loading-xs" />
            ) : (
              "Search"
            )}
          </button>
        </div>
      </form>

      {error && (
        <div className="alert alert-error mb-4">
          Search failed. Please try again.
        </div>
      )}

      {searchTerm.length === 0 ? (
        <p className="text-base-content/60">Enter a search term to find media.</p>
      ) : fetching ? (
        <div className="flex justify-center py-16">
          <span className="loading loading-spinner loading-lg" />
        </div>
      ) : results.length === 0 ? (
        <p className="text-base-content/60">
          No results found for &quot;{searchTerm}&quot;.
        </p>
      ) : (
        <div>
          <p className="text-sm text-base-content/60 mb-4">
            {totalCount} result{totalCount !== 1 ? "s" : ""} for &quot;{searchTerm}&quot;
          </p>
          <div className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 gap-4">
            {results.map((item) => (
              <a
                key={item.id}
                href={`/media/${item.id}`}
                className="card bg-base-100 shadow hover:shadow-lg transition-shadow"
              >
                <figure className="aspect-[2/3] bg-base-200">
                  {item.artwork?.posterUrl ? (
                    <img
                      src={item.artwork.posterUrl}
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
                </figure>
                <div className="card-body p-3">
                  <h3 className="text-sm font-semibold truncate">{item.title}</h3>
                  <p className="text-xs text-base-content/60">
                    {item.year ?? "---"} &middot; {item.type}
                  </p>
                </div>
              </a>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}
