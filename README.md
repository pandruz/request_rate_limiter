# request_rate_limiter

A **token-bucket rate limiter** for Dart and Flutter HTTP clients, with ready-made
adapters for [Dio](https://pub.dev/packages/dio) and
[http](https://pub.dev/packages/http).

- **Bursts allowed:** send up to `bucketSize` requests at once.
- **Steady rate afterwards:** the bucket refills at `tokensPerInterval` per `interval`.
- **Queues instead of dropping:** excess requests wait their turn, in order.
- **Optional hard limit** on the queue size (fail fast with a typed error).
- **Per-host (or any key) limits**, **request costs**, and **bypass rules**.
- **Cancellation-aware:** a request cancelled while queued is never sent and
  does not consume a token.
- Pure Dart. Works on Flutter (mobile, web, desktop) and the Dart VM.

## Which one do I use?

| You use...    | Import                                                   | Class                       |
| ------------- | -------------------------------------------------------- | --------------------------- |
| `dio`         | `package:request_rate_limiter/dio.dart`                  | `DioRateLimiterInterceptor` |
| `http`        | `package:request_rate_limiter/http.dart`                 | `HttpRateLimiterClient`     |
| anything else | `package:request_rate_limiter/request_rate_limiter.dart` | `TokenBucket`               |

The `http` package has no interceptors, so `HttpRateLimiterClient` is a wrapper
around an `http.Client` rather than an interceptor. Both adapters take the same
options and behave the same way.

## Installation

```yaml
dependencies:
  request_rate_limiter: ^0.1.0
```

This package depends on both `dio` and `http`, so both are downloaded. Only the
adapter you import ends up in your compiled app.

## Quick start: Dio

```dart
import 'package:dio/dio.dart';
import 'package:request_rate_limiter/dio.dart';

final dio = Dio();

dio.interceptors.add(
  DioRateLimiterInterceptor(
    bucketSize: 10,                               // burst of 10
    interval: const Duration(milliseconds: 500),  // every 500 ms...
    tokensPerInterval: 2,                         // ...add 2 tokens (4 req/s)
  ),
);
```

> **Add it first.** Interceptors run in the order they are added. Adding the
> rate limiter first means the limit applies before your other interceptors do
> any work, and retries that call `dio.fetch` again pass through it too.

## Quick start: http

```dart
import 'package:request_rate_limiter/http.dart';

final client = HttpRateLimiterClient(
  bucketSize: 10,
  interval: const Duration(milliseconds: 500),
  tokensPerInterval: 2,
);

final response = await client.get(Uri.parse('https://example.com'));

client.close();
```

Every method of the client (`get`, `post`, `read`, `send`, ...) is limited. To
wrap a client you already have, pass it as `inner:`. It is closed together with
the wrapper:

```dart
final client = HttpRateLimiterClient(inner: myExistingClient);
```

The defaults are a burst of 10 and a sustained 4 requests per second.

## How it works

The bucket starts full with `bucketSize` tokens. Each request consumes one
token. Tokens are added continuously at `tokensPerInterval / interval`, never
exceeding `bucketSize`. If no token is available, the request waits until one
is. Waiting requests are served first-in, first-out.

| Option              | Meaning                                            | Default           |
| ------------------- | -------------------------------------------------- | ----------------- |
| `bucketSize`        | Max tokens = largest possible burst                | `10`              |
| `interval`          | Refill period                                      | `500ms`           |
| `tokensPerInterval` | Tokens added per interval                          | `2`               |
| `maxQueueSize`      | Max requests allowed to wait (`null` = unlimited)  | `null`            |
| `shouldThrottle`    | Return `false` to bypass the limiter for a request | all throttled     |
| `cost`              | Tokens a request consumes (1 to `bucketSize`)      | `1`               |
| `bucketKey`         | Which bucket a request uses                        | one global bucket |

The three callbacks receive `RequestOptions` for Dio and `http.BaseRequest` for
`http`. The examples below show both.

## Recipes

### Skip the limiter for some requests

```dart
// Dio
DioRateLimiterInterceptor(
  shouldThrottle: (options) => !options.path.startsWith('/auth/'),
);

// http
HttpRateLimiterClient(
  shouldThrottle: (request) => !request.url.path.startsWith('/auth/'),
);
```

### Separate limit per host

```dart
// Dio
DioRateLimiterInterceptor(bucketKey: (options) => options.uri.host);

// http
HttpRateLimiterClient(bucketKey: (request) => request.url.host);
```

### Expensive endpoints cost more

```dart
// Dio
DioRateLimiterInterceptor(
  cost: (options) => options.path.startsWith('/search') ? 3 : 1,
);

// http
HttpRateLimiterClient(
  cost: (request) => request.url.path.startsWith('/search') ? 3 : 1,
);
```

### Fail fast instead of queueing

With `maxQueueSize` set, a request that finds the queue full is rejected. Use
`maxQueueSize: 0` to never wait at all.

With **Dio** the error arrives wrapped in a `DioException`:

```dart
try {
  await dio.get('/items');
} on DioException catch (e) {
  if (e.error is RateLimitOverflowException) {
    // Too many requests are already waiting. Back off or tell the user.
  }
}
```

With **http** the `RateLimitOverflowException` is thrown directly:

```dart
try {
  await client.get(uri);
} on RateLimitOverflowException {
  // Too many requests are already waiting.
}
```

### Cancelling queued requests

- **Dio:** cancel with a `CancelToken`. The call fails with a `DioException` of
  type `cancel`.
- **http:** use an `http.AbortableRequest` (requires `http` 1.3.0 or later) and
  complete its `abortTrigger`. The call throws an `http.RequestAbortedException`.

In both cases, a request cancelled while queued is never sent and does not
consume a token.

### Share one limit across clients

Create a `TokenBucket` yourself and hand it to any number of adapters. You can
even mix Dio and http:

```dart
final bucket = TokenBucket(bucketSize: 10, tokensPerInterval: 2);

dio.interceptors.add(DioRateLimiterInterceptor.shared(bucket));
final client = HttpRateLimiterClient.shared(bucket);

// You own a shared bucket, so dispose it yourself when you are done.
bucket.dispose();
```

### Use the bucket on its own

`TokenBucket` has no dependency on any HTTP client and can limit any async work:

```dart
final bucket = TokenBucket(bucketSize: 5, tokensPerInterval: 1);

await bucket.acquire();          // waits for a token
if (bucket.tryAcquire()) { ... } // or check without waiting
```

## Migrating from Angular + Porro

If you have this in an Angular interceptor:

```typescript
new Porro({ bucketSize: 10, interval: 500, tokensPerInterval: 2 });
```

the equivalent is:

```dart
DioRateLimiterInterceptor(
  bucketSize: 10,
  interval: const Duration(milliseconds: 500),
  tokensPerInterval: 2,
)
```

There is no `Bucket overflow` retry loop to write: queued requests simply wait.
One small difference is that Porro refills in discrete steps each interval,
while this package refills continuously, which is slightly smoother.

## Things to know

- **This is a client-side limit.** It protects you from exceeding a server's
  quota; it does not replace server-side limiting.
- **The limit is per process.** Multiple app instances or isolates each have
  their own bucket (a bucket cannot be shared across isolates).
- **Time spent in the queue does not count toward request timeouts.** Dio's
  `connectTimeout`, `sendTimeout` and `receiveTimeout` start when the request is
  actually sent. If you need an overall deadline, wrap the call in
  `Future.timeout` or set `maxQueueSize`.
- **Release resources.** Call `DioRateLimiterInterceptor.dispose()`,
  `HttpRateLimiterClient.close()` or `TokenBucket.dispose()` when you discard an
  instance, to release the internal timer.

## License

MIT. See [LICENSE](LICENSE).
