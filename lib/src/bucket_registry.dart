import 'token_bucket.dart';

/// Internal helper that maps a request key to the [TokenBucket] it draws from.
///
/// It either wraps one caller-owned shared bucket, or lazily creates one owned
/// bucket per key.
class BucketRegistry {
  /// Creates a registry that builds one bucket per key using [create].
  BucketRegistry.owned(TokenBucket Function() create)
      : _create = create,
        _shared = null;

  /// Creates a registry that always returns [bucket] and never disposes it.
  BucketRegistry.shared(TokenBucket bucket)
      : _create = null,
        _shared = bucket;

  final TokenBucket Function()? _create;
  final TokenBucket? _shared;
  final Map<String, TokenBucket> _buckets = <String, TokenBucket>{};

  /// Returns the bucket for [key].
  TokenBucket bucketFor(String key) {
    final shared = _shared;
    if (shared != null) return shared;
    return _buckets.putIfAbsent(key, _create!);
  }

  /// Disposes the buckets created by this registry (never a shared one).
  void dispose() {
    for (final bucket in _buckets.values) {
      bucket.dispose();
    }
    _buckets.clear();
  }
}
