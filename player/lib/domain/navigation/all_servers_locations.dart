/// Where the merged All servers views live.
library;

const allServersRoot = '/all';
const allServersMoviesLocation = '/all/movies';
const allServersShowsLocation = '/all/shows';
const allServersSearchLocation = '/all/search';
const allServersContinueWatchingLocation = '/all/continue-watching';
const allServersRecentlyAddedLocation = '/all/recently-added';
const allServersFavoritesLocation = '/all/favorites';
const allServersCollectionsLocation = '/all/collections';

/// Whether [location] is one of the merged `/all` views.
bool isAllServersLocation(String location) =>
    location == allServersRoot || location.startsWith('$allServersRoot/');
