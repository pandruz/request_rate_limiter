## 0.1.0

- Initial release.
- `TokenBucket`: standalone, dependency-free token bucket with FIFO queueing,
  optional queue limit, request cost and cancellation support.
- `DioRateLimiterInterceptor` (`package:request_rate_limiter/dio.dart`):
  Dio interceptor with global or keyed (e.g. per-host) buckets,
  `shouldThrottle` filter and per-request `cost`.
- `HttpRateLimiterClient` (`package:request_rate_limiter/http.dart`):
  `http.Client` wrapper with the same features, including support for
  `Abortable` requests.

## 0.2.0

- Fixed http package version in order to comply to pub.dev requirements
