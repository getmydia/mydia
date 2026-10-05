/// Encode and decode functions for what the source providers cache.
library;

import '../../../domain/sources/hub.dart';
import '../../../domain/sources/item.dart';
import '../../../domain/sources/library.dart';

Map<String, Object?> _map(Object? json) => json! as Map<String, Object?>;

Object? encodeSummaries(List<ItemSummary> items) =>
    [for (final i in items) i.toJson()];

List<ItemSummary> decodeSummaries(Object? json) =>
    [for (final e in json! as List) ItemSummary.fromJson(_map(e))];

Object? encodeLibraries(List<Library> libraries) =>
    [for (final l in libraries) l.toJson()];

List<Library> decodeLibraries(Object? json) =>
    [for (final e in json! as List) Library.fromJson(_map(e))];

/// Null means the source has no hubs, which is a value worth caching.
Object? encodeHubs(List<Hub>? hubs) =>
    hubs == null ? null : [for (final h in hubs) h.toJson()];

List<Hub>? decodeHubs(Object? json) =>
    json == null ? null : [for (final e in json as List) Hub.fromJson(_map(e))];

Object? encodeSummaryPage(Page<ItemSummary> page) =>
    page.toJson((i) => i.toJson());

Page<ItemSummary> decodeSummaryPage(Object? json) =>
    Page.fromJson(_map(json), ItemSummary.fromJson);

Object? encodeDetail(ItemDetail detail) => detail.toJson();

ItemDetail decodeDetail(Object? json) => ItemDetail.fromJson(_map(json));
