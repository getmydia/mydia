import { useState, useMemo, useEffect } from "react";
import { useQuery } from "urql";
import { CollectionsDocument } from "../graphql/generated/graphql";
import { PageHeader } from "../components/page-header";
import { Card } from "../components/card";
import { FilterBar } from "../components/filter-bar";

const TYPE_FILTERS = [
  { value: "all", label: "All Types" },
  { value: "manual", label: "Manual" },
  { value: "smart", label: "Smart" },
];

const VISIBILITY_FILTERS = [
  { value: "all", label: "All Visibility" },
  { value: "shared", label: "Shared" },
  { value: "private", label: "Private" },
];

function CollectionMosaic({ paths }: { paths: string[] }) {
  const posters = paths.slice(0, 4);
  const count = posters.length;

  if (count === 0) {
    return (
      <div className="aspect-[2/3] bg-base-200 flex items-center justify-center text-base-content/30">
        <svg xmlns="http://www.w3.org/2000/svg" className="w-10 h-10" fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={1} d="M2.25 12.75V12A2.25 2.25 0 014.5 9.75h15A2.25 2.25 0 0121.75 12v.75m-8.69-6.44l-2.12-2.12a1.5 1.5 0 00-1.061-.44H4.5A2.25 2.25 0 002.25 6v12a2.25 2.25 0 002.25 2.25h15A2.25 2.25 0 0021.75 18V9a2.25 2.25 0 00-2.25-2.25h-5.379a1.5 1.5 0 01-1.06-.44z" />
        </svg>
      </div>
    );
  }

  if (count === 1) {
    return (
      <div className="aspect-[2/3]">
        <img src={posters[0]} alt="" className="w-full h-full object-cover rounded-t-xl" loading="lazy" />
      </div>
    );
  }

  return (
    <div className={`aspect-[2/3] grid gap-px bg-base-300 ${count === 4 ? "grid-cols-2 grid-rows-2" : "grid-cols-2 grid-rows-1"}`}>
      {posters.map((url, i) => (
        <img key={i} src={url} alt="" className="w-full h-full object-cover" loading="lazy" />
      ))}
    </div>
  );
}

export function CollectionsPage() {
  const [viewMode, setViewMode] = useState<"grid" | "list">("grid");
  const [typeFilter, setTypeFilter] = useState("all");
  const [visibilityFilter, setVisibilityFilter] = useState("all");
  const [searchTerm, setSearchTerm] = useState("");
  const [debouncedSearch, setDebouncedSearch] = useState("");

  useEffect(() => {
    const timer = setTimeout(() => setDebouncedSearch(searchTerm), 300);
    return () => clearTimeout(timer);
  }, [searchTerm]);

  const [result] = useQuery({
    query: CollectionsDocument,
    variables: { first: 50 },
  });

  const allCollections = result.data?.collections ?? [];
  const fetching = result.fetching;
  const error = result.error;

  const collections = useMemo(() => {
    let filtered = allCollections;

    if (typeFilter === "manual") {
      filtered = filtered.filter((c) => c.type === "manual");
    } else if (typeFilter === "smart") {
      filtered = filtered.filter((c) => c.type === "smart");
    }

    if (visibilityFilter === "private") {
      filtered = filtered.filter((c) => c.visibility === "private");
    } else if (visibilityFilter === "shared") {
      filtered = filtered.filter((c) => c.visibility === "shared");
    }

    if (debouncedSearch) {
      const q = debouncedSearch.toLowerCase();
      filtered = filtered.filter((c) =>
        c.name.toLowerCase().includes(q)
      );
    }

    return filtered;
  }, [allCollections, typeFilter, visibilityFilter, debouncedSearch]);

  return (
    <div>
      <PageHeader
        title="Collections"
        subtitle={`${allCollections.length} collections`}
        actions={
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
        }
      />

      <div className="flex flex-col sm:flex-row sm:items-center gap-3 mb-4">
        <input
          type="text"
          placeholder="Search collections..."
          className="input input-bordered input-sm w-full sm:max-w-xs"
          value={searchTerm}
          onChange={(e) => setSearchTerm(e.target.value)}
        />
        <FilterBar current={typeFilter} options={TYPE_FILTERS} onChange={setTypeFilter} />
        <FilterBar current={visibilityFilter} options={VISIBILITY_FILTERS} onChange={setVisibilityFilter} />
      </div>

      {error && (
        <div className="alert alert-error mb-4">
          Failed to load collections.
        </div>
      )}

      {fetching && collections.length === 0 ? (
        <div className="flex justify-center py-16">
          <span className="loading loading-spinner loading-lg" />
        </div>
      ) : collections.length === 0 ? (
        <Card>
          <div className="text-center py-8">
            <p className="text-base-content/60">
              {debouncedSearch ? "No collections match your search." : "No collections yet. Create one to organize your media."}
            </p>
          </div>
        </Card>
      ) : viewMode === "grid" ? (
        <div className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6 gap-4">
          {collections.map((col) => (
            <a
              key={col.id}
              href={`/collections/${col.id}`}
              className="card bg-base-100 shadow hover:shadow-lg transition-shadow group"
            >
              <figure>
                <CollectionMosaic paths={col.posterPaths} />
              </figure>
              <div className="card-body p-3">
                <h3 className="text-sm font-semibold truncate">{col.name}</h3>
                <div className="flex items-center justify-between text-xs text-base-content/60">
                  <div className="flex items-center gap-1">
                    <span className={["badge badge-xs", col.type === "smart" ? "badge-info" : "badge-ghost"].join(" ")}>
                      {col.type}
                    </span>
                    <span className="badge badge-xs badge-ghost">
                      {col.visibility}
                    </span>
                  </div>
                  <span>{col.itemCount} items</span>
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
                <th>Name</th>
                <th>Type</th>
                <th>Visibility</th>
                <th>Items</th>
              </tr>
            </thead>
            <tbody>
              {collections.map((col) => (
                <tr key={col.id} className="hover cursor-pointer" onClick={() => window.location.assign(`/collections/${col.id}`)}>
                  <td>
                    <div className="font-semibold text-sm">{col.name}</div>
                    {col.description && (
                      <div className="text-xs text-base-content/50 truncate max-w-xs">{col.description}</div>
                    )}
                  </td>
                  <td>
                    <span className={["badge badge-sm", col.type === "smart" ? "badge-info" : "badge-ghost"].join(" ")}>
                      {col.type}
                    </span>
                  </td>
                  <td>
                    <span className="badge badge-sm badge-ghost">{col.visibility}</span>
                  </td>
                  <td className="text-sm">{col.itemCount}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
