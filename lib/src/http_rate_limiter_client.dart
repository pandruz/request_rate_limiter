import 'package:http/http.dart' as http;

import 'bucket_registry.dart';
import 'exceptions.dart';
import 'token_bucket.dart';

/// Decides whether an `http` request is subject to rate limiting.
typedef HttpThrottlePredicate = bool Function(http.BaseRequest request);

/// Computes how many tokens an `http` request consumes.
typedef HttpRequestCost = int Function(http.BaseRequest request);

/// Computes the key that selects which bucket an `http` request draws from.
typedef HttpBucketKeyBuilder = String Function(http.BaseRequest request);

/// An [http.Client] that rate limits requests with a [TokenBucket].
///
/// The `http` package has no interceptors, so this class wraps another client
/// and delays [send] until a token is available. Because every convenience
/// method of [http.BaseClient] (`get`, `post`, `read`, ...) goes through
/// [send], all of them are limited.
///
/// ```dart
/// final client = HttpRateLimiterClient(
///   bucketSize: 10,
///   interval: const Duration(milliseconds: 500),
///   tokensPerInterval: 2,
/// );
///
/// final response = await client.get(Uri.parse('https://example.com'));
/// client.close();
/// ```
///
/// To wrap a client you already have (for example one from `cronet_http` or
/// `cupertino_http`), pass it as [inner]. It is closed when this client is
/// closed.
///
/// ### Cancellation
///
/// If the request is an [http.Abortable] request (`http` 1.3.0 and later) and
/// its `abortTrigger` completes while the request is still queued, the request
/// is never sent and [send] throws an [http.RequestAbortedException].
///
/// ### Errors
///
/// When a `maxQueueSize` is set and the queue is full, [send] throws a
/// [RateLimitOverflowException].
///
/// For Dio, see `DioRateLimiterInterceptor` instead.
class HttpRateLimiterClient extends http.BaseClient {
  /// Creates a client that owns its bucket(s).
  ///
  /// [bucketSize], [interval], [tokensPerInterval] and [maxQueueSize] have the
  /// same meaning as in [TokenBucket].
  ///
  /// * [inner] is the client that actually sends requests. Defaults to a new
  ///   [http.Client].
  /// * [shouldThrottle] can return `false` to let a request bypass the limiter.
  ///   By default every request is throttled.
  /// * [cost] sets how many tokens a request consumes. Defaults to 1. It must
  ///   return a value between 1 and [bucketSize].
  /// * [bucketKey] selects the bucket for a request, for example
  ///   `(r) => r.url.host` for per-host limits. By default all requests share
  ///   a single bucket.
  HttpRateLimiterClient({
    http.Client? inner,
    int bucketSize = 10,
    Duration interval = const Duration(milliseconds: 500),
    int tokensPerInterval = 2,
    int? maxQueueSize,
    this.shouldThrottle,
    this.cost,
    this.bucketKey,
  })  : _inner = inner ?? http.Client(),
        _buckets = BucketRegistry.owned(
          () => TokenBucket(
            bucketSize: bucketSize,
            interval: interval,
            tokensPerInterval: tokensPerInterval,
            maxQueueSize: maxQueueSize,
          ),
        );

  /// Creates a client that draws from an existing [bucket].
  ///
  /// Use this to share one rate limit across several clients, or between an
  /// `http` client and a Dio instance. Closing this client does **not**
  /// dispose a shared bucket; the caller owns it.
  HttpRateLimiterClient.shared(
    TokenBucket bucket, {
    http.Client? inner,
    this.shouldThrottle,
    this.cost,
  })  : _inner = inner ?? http.Client(),
        _buckets = BucketRegistry.shared(bucket),
        bucketKey = null;

  /// Returns `false` for requests that must bypass rate limiting.
  final HttpThrottlePredicate? shouldThrottle;

  /// Returns the number of tokens a request consumes (default 1).
  final HttpRequestCost? cost;

  /// Returns the key selecting the bucket for a request (default: one global
  /// bucket).
  final HttpBucketKeyBuilder? bucketKey;

  final http.Client _inner;
  final BucketRegistry _buckets;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (shouldThrottle != null && !shouldThrottle!(request)) {
      return _inner.send(request);
    }

    final bucket = _buckets.bucketFor(bucketKey?.call(request) ?? '');
    try {
      await bucket.acquire(
        tokens: cost?.call(request) ?? 1,
        cancelSignal: request is http.Abortable ? request.abortTrigger : null,
      );
    } on RateLimitCancelledException {
      throw http.RequestAbortedException(request.url);
    }

    return _inner.send(request);
  }

  /// Closes the inner client and disposes the buckets created by this client.
  ///
  /// Buckets passed to [HttpRateLimiterClient.shared] are not disposed.
  /// Requests still waiting fail with an [http.RequestAbortedException].
  @override
  void close() {
    _buckets.dispose();
    _inner.close();
  }
}
