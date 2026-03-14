import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

class VpsEmbeddingsApiException implements Exception {
  VpsEmbeddingsApiException({
    required this.statusCode,
    required this.requestUrl,
    this.responseBody,
  });

  final int statusCode;
  final String requestUrl;
  final String? responseBody;

  @override
  String toString() {
    final String body = responseBody == null ? '' : ' body=$responseBody';
    return 'VpsEmbeddingsApiException(statusCode=$statusCode, url=$requestUrl$body)';
  }
}

class VpsEmbeddingsRecord {
  const VpsEmbeddingsRecord({
    required this.uid,
    required this.embedding,
    required this.embeddings,
    this.model,
    this.updatedAt,
    this.updatedBy,
  });

  final String uid;
  final List<double> embedding;
  final List<List<double>> embeddings;
  final String? model;
  final String? updatedAt;
  final String? updatedBy;

  bool get hasAnyEmbedding => embedding.isNotEmpty || embeddings.isNotEmpty;

  static VpsEmbeddingsRecord fromJson(Map<String, dynamic> json) {
    final String uid = (json['uid'] as String?)?.trim() ?? '';
    final Object? rawEmbedding = json['embedding'];
    final List<double> embedding = rawEmbedding is List
        ? rawEmbedding
            .whereType<num>()
            .map((num v) => v.toDouble())
            .toList(growable: false)
        : <double>[];

    final Object? rawEmbeddings = json['embeddings'];
    final List<List<double>> embeddings = rawEmbeddings is List
        ? rawEmbeddings
            .whereType<List>()
            .map(
              (List<dynamic> row) => row
                  .whereType<num>()
                  .map((num v) => v.toDouble())
                  .toList(growable: false),
            )
            .where((List<double> v) => v.isNotEmpty)
            .toList(growable: false)
        : <List<double>>[];

    return VpsEmbeddingsRecord(
      uid: uid,
      embedding: embedding,
      embeddings: embeddings,
      model: json['model'] as String?,
      updatedAt: json['updatedAt'] as String?,
      updatedBy: json['updatedBy'] as String?,
    );
  }
}

class VpsEmbeddingsApiClient {
  const VpsEmbeddingsApiClient({
    this.baseUrl = 'https://embeddings.shiro.codes',
    this.timeout = const Duration(seconds: 12),
  });

  final String baseUrl;
  final Duration timeout;

  Future<bool> healthz({Duration? timeoutOverride}) async {
    final Uri uri = Uri.parse('$baseUrl/healthz');
    try {
      final http.Response response = await http
          .get(
            uri,
            headers: const <String, String>{
              'Accept': 'application/json',
            },
          )
          .timeout(timeoutOverride ?? const Duration(seconds: 4));
      if (response.statusCode != 200) return false;
      final Object? decoded = jsonDecode(response.body);
      return decoded is Map<String, dynamic> && decoded['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  Future<String> _getRequiredIdToken(User user, bool forceRefreshToken) async {
    final String? token = await user.getIdToken(forceRefreshToken);
    if (token == null || token.trim().isEmpty) {
      throw StateError('Unable to fetch Firebase ID token.');
    }
    return token;
  }

  Future<VpsEmbeddingsRecord?> getEmbeddingForUid(
    String uid, {
    bool forceRefreshToken = false,
  }) async {
    final User? user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw StateError('Not signed in.');
    }
    final Uri uri = Uri.parse('$baseUrl/v1/embeddings/$uid');
    final String token = await _getRequiredIdToken(user, forceRefreshToken);

    final http.Response response = await http
        .get(
          uri,
          headers: <String, String>{
            'Authorization': 'Bearer $token',
            'Accept': 'application/json',
          },
        )
        .timeout(timeout);

    if (response.statusCode == 404) {
      return null;
    }
    if (response.statusCode != 200) {
      throw VpsEmbeddingsApiException(
        statusCode: response.statusCode,
        requestUrl: uri.toString(),
        responseBody: response.body,
      );
    }

    final Object? decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw FormatException('Unexpected JSON response shape.');
    }
    final VpsEmbeddingsRecord record = VpsEmbeddingsRecord.fromJson(decoded);
    if (!record.hasAnyEmbedding) {
      throw FormatException('VPS record contains no embedding values.');
    }
    return record;
  }

  Future<void> putEmbeddingForUid(
    String uid, {
    required List<double> embedding,
    required String model,
    bool forceRefreshToken = true,
  }) async {
    final User? user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw StateError('Not signed in.');
    }
    if (embedding.isEmpty) {
      throw ArgumentError.value(embedding, 'embedding', 'Must not be empty.');
    }

    final Uri uri = Uri.parse('$baseUrl/v1/embeddings/$uid');
    final String token = await _getRequiredIdToken(user, forceRefreshToken);

    final Map<String, dynamic> body = <String, dynamic>{
      'embedding': embedding,
      'model': model,
    };

    final http.Response response = await http
        .put(
          uri,
          headers: <String, String>{
            'Authorization': 'Bearer $token',
            'Accept': 'application/json',
            'Content-Type': 'application/json; charset=utf-8',
          },
          body: jsonEncode(body),
        )
        .timeout(timeout);

    if (response.statusCode != 200) {
      throw VpsEmbeddingsApiException(
        statusCode: response.statusCode,
        requestUrl: uri.toString(),
        responseBody: response.body,
      );
    }
  }

  Future<void> putEmbeddingsForUid(
    String uid, {
    required List<List<double>> embeddings,
    List<double>? embedding,
    required String model,
    bool forceRefreshToken = true,
  }) async {
    final User? user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw StateError('Not signed in.');
    }
    if (embeddings.isEmpty) {
      throw ArgumentError.value(embeddings, 'embeddings', 'Must not be empty.');
    }

    final Uri uri = Uri.parse('$baseUrl/v1/embeddings/$uid');
    final String token = await _getRequiredIdToken(user, forceRefreshToken);

    final Map<String, dynamic> body = <String, dynamic>{
      'embeddings': embeddings,
      'model': model,
    };
    if (embedding != null && embedding.isNotEmpty) {
      body['embedding'] = embedding;
    }

    final http.Response response = await http
        .put(
          uri,
          headers: <String, String>{
            'Authorization': 'Bearer $token',
            'Accept': 'application/json',
            'Content-Type': 'application/json; charset=utf-8',
          },
          body: jsonEncode(body),
        )
        .timeout(timeout);

    if (response.statusCode != 200) {
      throw VpsEmbeddingsApiException(
        statusCode: response.statusCode,
        requestUrl: uri.toString(),
        responseBody: response.body,
      );
    }
  }

  Future<bool> deleteEmbeddingForUid(
    String uid, {
    bool forceRefreshToken = true,
  }) async {
    final User? user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw StateError('Not signed in.');
    }
    final Uri uri = Uri.parse('$baseUrl/v1/embeddings/$uid');
    final String token = await _getRequiredIdToken(user, forceRefreshToken);

    final http.Response response = await http
        .delete(
          uri,
          headers: <String, String>{
            'Authorization': 'Bearer $token',
            'Accept': 'application/json',
          },
        )
        .timeout(timeout);

    if (response.statusCode == 404) {
      return false;
    }
    if (response.statusCode != 200) {
      throw VpsEmbeddingsApiException(
        statusCode: response.statusCode,
        requestUrl: uri.toString(),
        responseBody: response.body,
      );
    }

    try {
      final Object? decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        final Object? rawDeleted = decoded['deleted'];
        if (rawDeleted is bool) {
          return rawDeleted;
        }
      }
    } catch (_) {
      // Ignore body parse errors; a 200 still means success.
    }
    return true;
  }
}
