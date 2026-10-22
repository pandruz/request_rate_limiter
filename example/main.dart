import 'package:dio/dio.dart';
import 'package:request_rate_limiter/dio.dart';
import 'package:request_rate_limiter/http.dart';

Future<void> main() async {
  await dioExample();
  await httpExample();
  await sharedExample();
}

/// Rate limiting with Dio.
Future<void> dioExample() async {
  final dio = Dio();

  // Burst of up to 10 requests, then 2 more every 500 ms (4 per second).
  // Add it FIRST so it runs before your other interceptors.
  dio.interceptors.add(
    DioRateLimiterInterceptor(
      bucketSize: 10,
      interval: const Duration(milliseconds: 500),
      tokensPerInterval: 2,
      // Optional: skip the limiter for some requests.
      shouldThrottle: (options) => !options.path.endsWith('/health'),
      // Optional: a separate limit per host.
      bucketKey: (options) => options.uri.host,
    ),
  );

  final stopwatch = Stopwatch()..start();
  await Future.wait([
    for (var i = 0; i < 20; i++)
      dio.get<void>('https://example.com/').then((_) {
        print('dio request $i done after ${stopwatch.elapsedMilliseconds} ms');
      }),
  ]);
}

/// Rate limiting with the `http` package.
Future<void> httpExample() async {
  // Wraps a default http.Client. Pass `inner:` to wrap your own client.
  final client = HttpRateLimiterClient(
    bucketSize: 10,
    interval: const Duration(milliseconds: 500),
    tokensPerInterval: 2,
    // Optional: a separate limit per host.
    bucketKey: (request) => request.url.host,
  );

  final stopwatch = Stopwatch()..start();
  await Future.wait([
    for (var i = 0; i < 20; i++)
      client.get(Uri.parse('https://example.com/')).then((_) {
        print('http request $i done after ${stopwatch.elapsedMilliseconds} ms');
      }),
  ]);

  client.close();
}

/// One limit shared by a Dio instance and an http client.
Future<void> sharedExample() async {
  final bucket = TokenBucket(bucketSize: 10, tokensPerInterval: 2);

  final dio = Dio()..interceptors.add(DioRateLimiterInterceptor.shared(bucket));
  final client = HttpRateLimiterClient.shared(bucket);

  await dio.get<void>('https://example.com/');
  await client.get(Uri.parse('https://example.com/'));

  client.close();
  bucket.dispose(); // you own a shared bucket
}
