import 'package:dio/dio.dart';

import 'bucket_registry.dart';
import 'exceptions.dart';
import 'token_bucket.dart';

/// Decides whether a Dio request is subject to rate limiting.
typedef DioThrottlePredicate = bool Function(RequestOptions options);

/// Computes how many tokens a Dio request consumes.
typedef DioRequestCost = int Function(RequestOptions options);

/// Computes the key that selects which bucket a Dio request draws from.
typedef DioBucketKeyBuilder = String Function(RequestOptions options);

/// A Dio [Interceptor] that rate limits outgoing requests with a
/// [TokenBucket].
///
/// Requests may burst up to [TokenBucket.bucketSize] and are then released at
/// a steady rate. Requests that exceed the rate are **queued** (in order)
/// rather than rejected, unless a `maxQueueSize` is set.
///
/// ```dart
/// final dio = Dio();
/// dio.interceptors.add(
///   DioRateLimiterInterceptor(
///     bucketSize: 10,
///     interval: const Duration(milliseconds: 500),
///     tokensPerInterval: 2,
///   ),
/// );
/// ```
///
/// ### Order matters
///
/// Interceptors run in the order they were added. Add this interceptor
/// **first** so the rate limit applies before other interceptors do work, and
/// so that retries issued by later interceptors (which call `dio.fetch`
/// again) pass through it as well.
///
/// ### Errors
///
/// * A request rejected because the queue is full fails with a
///   [DioException] whose `error` is a [RateLimitOverflowException].
/// * A request cancelled with a `CancelToken` while queued fails with a
///   [DioException] of type [DioExceptionType.cancel] and is never sent.
///
/// For the `http` package, see `HttpRateLimiterClient` instead.
class DioRateLimiterInterceptor extends Interceptor {
  /// Creates an interceptor that owns its bucket(s).
  ///
  /// [bucketSize], [interval], [tokensPerInterval] and [maxQueueSize] have the
  /// same meaning as in [TokenBucket].
  ///
  /// * [shouldThrottle] can return `false` to let a request bypass the limiter
  ///   (for example for health checks or token refresh calls). By default every
  ///   request is throttled.
  /// * [cost] sets how many tokens a request consumes. Defaults to 1. It must
  ///   return a value between 1 and [bucketSize].
  /// * [bucketKey] selects the bucket for a request. Requests with the same key
  ///   share a bucket, for example `(o) => o.uri.host` for per-host limits. By
  ///   default all requests share a single bucket.
  DioRateLimiterInterceptor({
    int bucketSize = 10,
    Duration interval = const Duration(milliseconds: 500),
    int tokensPerInterval = 2,
    int? maxQueueSize,
    this.shouldThrottle,
    this.cost,
    this.bucketKey,
  }) : _buckets = BucketRegistry.owned(
          () => TokenBucket(
            bucketSize: bucketSize,
            interval: interval,
            tokensPerInterval: tokensPerInterval,
            maxQueueSize: maxQueueSize,
          ),
        );

  /// Creates an interceptor that draws from an existing [bucket].
  ///
  /// Use this to share one rate limit across several `Dio` instances, or even
  /// between a `Dio` instance and an `HttpRateLimiterClient`. The interceptor
  /// does **not** dispose a shared bucket; the caller owns it.
  DioRateLimiterInterceptor.shared(
    TokenBucket bucket, {
    this.shouldThrottle,
    this.cost,
  })  : _buckets = BucketRegistry.shared(bucket),
        bucketKey = null;

  /// Returns `false` for requests that must bypass rate limiting.
  final DioThrottlePredicate? shouldThrottle;

  /// Returns the number of tokens a request consumes (default 1).
  final DioRequestCost? cost;

  /// Returns the key selecting the bucket for a request (default: one global
  /// bucket).
  final DioBucketKeyBuilder? bucketKey;

  final BucketRegistry _buckets;

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    if (shouldThrottle != null && !shouldThrottle!(options)) {
      handler.next(options);
      return;
    }

    final bucket = _buckets.bucketFor(bucketKey?.call(options) ?? '');
    try {
      await bucket.acquire(
        tokens: cost?.call(options) ?? 1,
        cancelSignal: options.cancelToken?.whenCancel,
      );
    } on RateLimitOverflowException catch (e) {
      handler.reject(
        DioException(
          requestOptions: options,
          type: DioExceptionType.unknown,
          error: e,
          message: e.message,
        ),
      );
      return;
    } on RateLimitCancelledException {
      handler.reject(
        DioException.requestCancelled(
          requestOptions: options,
          reason: options.cancelToken?.cancelError,
        ),
      );
      return;
    }

    handler.next(options);
  }

  /// Disposes the buckets created by this interceptor.
  ///
  /// Buckets passed to [DioRateLimiterInterceptor.shared] are not disposed.
  /// Requests still waiting are rejected as cancelled.
  void dispose() => _buckets.dispose();
}
