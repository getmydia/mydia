/// What a Mydia server handed this device, kept as one secret.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

@immutable
class MydiaCredentials {
  const MydiaCredentials({
    required this.instanceId,
    required this.accessToken,
    this.instanceName,
    this.mediaToken,
    this.mediaTokenExpiry,
    this.deviceToken,
    this.serverUrl,
    this.nodeAddr,
    this.username,
  });

  factory MydiaCredentials.fromJson(Map<String, dynamic> json) =>
      MydiaCredentials(
        instanceId: json['instanceId'] as String,
        accessToken: json['accessToken'] as String,
        instanceName: json['instanceName'] as String?,
        mediaToken: json['mediaToken'] as String?,
        mediaTokenExpiry: json['mediaTokenExpiry'] != null
            ? DateTime.tryParse(json['mediaTokenExpiry'] as String)
            : null,
        deviceToken: json['deviceToken'] as String?,
        serverUrl: json['serverUrl'] as String?,
        nodeAddr: json['nodeAddr'] as String?,
        username: json['username'] as String?,
      );

  final String instanceId;
  final String accessToken;
  final String? instanceName;
  final String? mediaToken;
  final DateTime? mediaTokenExpiry;

  /// Trades for a fresh access token when the server rejects the current
  /// one. Only paired devices have it; a URL login signs in again instead.
  final String? deviceToken;

  /// Set for a URL login: the base the GraphQL and HLS paths hang off.
  final String? serverUrl;

  /// Set for a paired server: the server's iroh EndpointAddr JSON.
  final String? nodeAddr;
  final String? username;

  bool get isP2p => nodeAddr != null;

  String? get nodeId {
    final addr = nodeAddr;
    if (addr == null) return null;
    try {
      final decoded = jsonDecode(addr);
      return decoded is Map ? decoded['id'] as String? : null;
    } on FormatException {
      return null;
    }
  }

  Map<String, dynamic> toJson() => {
        'instanceId': instanceId,
        'accessToken': accessToken,
        if (instanceName != null) 'instanceName': instanceName,
        if (mediaToken != null) 'mediaToken': mediaToken,
        if (mediaTokenExpiry != null)
          'mediaTokenExpiry': mediaTokenExpiry!.toIso8601String(),
        if (deviceToken != null) 'deviceToken': deviceToken,
        if (serverUrl != null) 'serverUrl': serverUrl,
        if (nodeAddr != null) 'nodeAddr': nodeAddr,
        if (username != null) 'username': username,
      };

  MydiaCredentials copyWith({
    String? accessToken,
    String? mediaToken,
    DateTime? mediaTokenExpiry,
  }) =>
      MydiaCredentials(
        instanceId: instanceId,
        accessToken: accessToken ?? this.accessToken,
        instanceName: instanceName,
        mediaToken: mediaToken ?? this.mediaToken,
        mediaTokenExpiry: mediaTokenExpiry ?? this.mediaTokenExpiry,
        deviceToken: deviceToken,
        serverUrl: serverUrl,
        nodeAddr: nodeAddr,
        username: username,
      );

  @override
  bool operator ==(Object other) =>
      other is MydiaCredentials &&
      other.instanceId == instanceId &&
      other.accessToken == accessToken &&
      other.instanceName == instanceName &&
      other.mediaToken == mediaToken &&
      other.mediaTokenExpiry == mediaTokenExpiry &&
      other.deviceToken == deviceToken &&
      other.serverUrl == serverUrl &&
      other.nodeAddr == nodeAddr &&
      other.username == username;

  @override
  int get hashCode => Object.hash(
        instanceId,
        accessToken,
        instanceName,
        mediaToken,
        mediaTokenExpiry,
        deviceToken,
        serverUrl,
        nodeAddr,
        username,
      );
}

/// Scheme, lowercased host and port, with no trailing slash, so the same
/// server typed two ways is one instance.
String normalizeMydiaUrl(String url) {
  final uri = Uri.parse(url.trim());
  final port = uri.hasPort ? ':${uri.port}' : '';
  final path = uri.path.endsWith('/')
      ? uri.path.substring(0, uri.path.length - 1)
      : uri.path;
  return '${uri.scheme}://${uri.host.toLowerCase()}$port$path';
}

/// The id of a URL-login server whose server reports no instance id.
String urlInstanceId(String url) {
  final digest = sha256.convert(utf8.encode(normalizeMydiaUrl(url)));
  return 'u${digest.toString().substring(0, 16)}';
}

/// The id of a paired server whose server reports no instance id. A node id
/// is the server's key, stable for as long as its keypair is.
String nodeInstanceId(String nodeId) => 'n$nodeId';
