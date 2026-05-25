import { useQuery } from "urql";
import { DiscoverRecentlyAddedDocument } from "../graphql/generated/graphql";
import { PageHeader } from "../components/page-header";
import { Card } from "../components/card";

export function DiscoverPage() {
  const [{ data, fetching, error }] = useQuery({
    query: DiscoverRecentlyAddedDocument,
    variables: { first: 20 },
  });

  const items = data?.recentlyAdded ?? [];

  return (
    <div>
      <PageHeader title="Discover" subtitle="Recently added to your library" />

      {error && (
        <div className="alert alert-error mb-4">
          Failed to load discoveries.
        </div>
      )}

      {fetching && items.length === 0 ? (
        <div className="flex justify-center py-16">
          <span className="loading loading-spinner loading-lg" />
        </div>
      ) : items.length === 0 ? (
        <Card>
          <p className="text-base-content/60">
            No recently added items. Add media to your library to get started.
          </p>
        </Card>
      ) : (
        <div className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 gap-4">
          {items.map((item) => (
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
      )}
    </div>
  );
}
