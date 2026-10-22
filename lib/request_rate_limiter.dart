/// A token-bucket rate limiter for HTTP clients.
///
/// This library contains the client-independent core: [TokenBucket] and its
/// exceptions. To limit requests made with a specific client, import one of
/// the adapters:
///
/// * `package:request_rate_limiter/dio.dart` for
///   [Dio](https://pub.dev/packages/dio) (`DioRateLimiterInterceptor`).
/// * `package:request_rate_limiter/http.dart` for
///   [http](https://pub.dev/packages/http) (`HttpRateLimiterClient`).
library;

export 'src/exceptions.dart';
export 'src/token_bucket.dart';
