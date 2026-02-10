class FaceQualityException implements Exception {
  FaceQualityException(this.message);

  final String message;

  @override
  String toString() => 'FaceQualityException: $message';
}
