import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:request_rate_limiter/dio.dart';
import 'package:test/test.dart';

/// Answers every request with 200 and records when it was received.
class _RecordingAdapter implements HttpClientAdapter {
  final Stopwatch _clock = Stopwatch()..start();
  final List<int> times = <int>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    times.add(_clock.elapsedMilliseconds);
    return ResponseBody.fromString('ok', 200);
  }

  @override
  void close({bool force = false}) {}
}

Dio _dioWith(DioRateLimiterInterceptor interceptor, _RecordingAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'https://example.com'));
  dio.httpClientAdapter = adapter;
  dio.interceptors.add(interceptor);
  return dio;
}

void main() {
  test('lets a burst through and delays the rest', () async {
    final adapter = _RecordingAdapter();
    final dio = _dioWith(DioRateLimiterInterceptor(bucketSize: 3, interval: const Duration(milliseconds: 100), tokensPerInterval: 1), adapter);

    await Future.wait([for (var i = 0; i < 4; i++) dio.get<String>('/a')]);

    expect(adapter.times, hasLength(4));
    expect(adapter.times[2], lessThan(60)); // burst of 3 is immediate
    expect(adapter.times[3], greaterThanOrEqualTo(80)); // 4th waits ~100 ms
  });

  test('shouldThrottle can exempt requests', () async {
    final adapter = _RecordingAdapter();
    final dio = _dioWith(
      DioRateLimiterInterceptor(
        bucketSize: 1,
        interval: const Duration(seconds: 10),
        tokensPerInterval: 1,
        shouldThrottle: (options) => !options.path.contains('health'),
      ),
      adapter,
    );

    await dio.get<String>('/a'); // uses the only token
    await dio.get<String>('/health'); // bypasses the limiter
    await dio.get<String>('/health');

    expect(adapter.times, hasLength(3));
    expect(adapter.times.last, lessThan(500));
  });

  test('bucketKey gives each key its own bucket', () async {
    final adapter = _RecordingAdapter();
    final dio = _dioWith(
      DioRateLimiterInterceptor(bucketSize: 1, interval: const Duration(seconds: 10), tokensPerInterval: 1, bucketKey: (options) => options.path),
      adapter,
    );

    await dio.get<String>('/a');
    await dio.get<String>('/b'); // different key, so no waiting

    expect(adapter.times, hasLength(2));
    expect(adapter.times.last, lessThan(500));
  });

  test('rejects with RateLimitOverflowException when the queue is full', () async {
    final adapter = _RecordingAdapter();
    final dio = _dioWith(
      DioRateLimiterInterceptor(bucketSize: 1, interval: const Duration(seconds: 10), tokensPerInterval: 1, maxQueueSize: 0),
      adapter,
    );

    await dio.get<String>('/a');

    await expectLater(dio.get<String>('/b'), throwsA(isA<DioException>().having((e) => e.error, 'error', isA<RateLimitOverflowException>())));
    expect(adapter.times, hasLength(1));
  });

  test('a request cancelled while queued is never sent', () async {
    final adapter = _RecordingAdapter();
    final dio = _dioWith(DioRateLimiterInterceptor(bucketSize: 1, interval: const Duration(seconds: 10), tokensPerInterval: 1), adapter);

    await dio.get<String>('/a');

    final cancelToken = CancelToken();
    final future = dio.get<String>('/b', cancelToken: cancelToken);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    cancelToken.cancel('changed my mind');

    await expectLater(future, throwsA(isA<DioException>().having((e) => e.type, 'type', DioExceptionType.cancel)));
    expect(adapter.times, hasLength(1));
  });

  test('shared bucket is not disposed by the interceptor', () async {
    final bucket = TokenBucket(bucketSize: 2);
    final interceptor = DioRateLimiterInterceptor.shared(bucket);

    interceptor.dispose();

    expect(bucket.tryAcquire(), isTrue);
    bucket.dispose();
  });
}
