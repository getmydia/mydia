import 'guest_mydia.graphql.dart';

export 'calendar.graphql.dart' show documentNodeQueryCalendar;
export 'collections.graphql.dart'
    show documentNodeQueryCollections, documentNodeQueryCollectionItems;
export 'continue_watching_full.graphql.dart'
    show
        documentNodeQueryContinueWatchingFull,
        documentNodeQueryContinueWatchingFullLegacy;
export 'home_rows.graphql.dart'
    show documentNodeQueryHomeRows, documentNodeQueryHomeRowsLegacy;
export 'library_filtered.graphql.dart'
    show documentNodeQueryMoviesFiltered, documentNodeQueryTvShowsFiltered;
export 'listings.graphql.dart'
    show documentNodeQueryUnwatchedListing, documentNodeQueryFavoritesListing;
export 'recently_added_full.graphql.dart'
    show
        documentNodeQueryRecentlyAddedFull,
        documentNodeQueryRecentlyAddedFullLegacy;

const documentNodeQueryMydiaInstanceIdentity =
    documentNodeQueryGuestInstanceIdentity;
const documentNodeQueryMydiaMovies = documentNodeQueryGuestMovies;
const documentNodeQueryMydiaTvShows = documentNodeQueryGuestTvShows;
const documentNodeQueryMydiaRecentlyAdded = documentNodeQueryGuestRecentlyAdded;
const documentNodeQueryMydiaContinueWatching =
    documentNodeQueryGuestContinueWatching;
