import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:request_rate_limiter/http.dart';
import 'package:test/test.dart';

/// Builds a client whose inner client records when each request arrives.
({HttpRateLimiterClient client, List<int> times}) _build({
  int bucketSize = 10,
  Duration interval = const Duration(milliseconds: 500),
  int tokensPerInterval = 2,
  int? maxQueueSize,
  HttpThrottlePredicate? shouldThrottle,
  HttpBucketKeyBuilder? bucketKey,
  HttpRequestCost? cost,
}) {
  final clock = Stopwatch()..start();
  final times = <int>[];
  final inner = MockClient((request) async {
    times.add(clock.elapsedMilliseconds);
    return http.Response('ok', 200);
  });
  final client = HttpRateLimiterClient(
    inner: inner,
    bucketSize: bucketSize,
    interval: interval,
    tokensPerInterval: tokensPerInterval,
    maxQueueSize: maxQueueSize,
    shouldThrottle: shouldThrottle,
    bucketKey: bucketKey,
    cost: cost,
  );
  return (client: client, times: times);
}

Uri _uri(String path, {String host = 'example.com'}) => Uri.parse('https://$host$path');

void main() {
  test('lets a burst through and delays the rest', () async {
    final (:client, :times) = _build(bucketSize: 3, interval: const Duration(milliseconds: 100), tokensPerInterval: 1);

    await Future.wait([for (var i = 0; i < 4; i++) client.get(_uri('/a'))]);

    expect(times, hasLength(4));
    expect(times[2], lessThan(60)); // burst of 3 is immediate
    expect(times[3], greaterThanOrEqualTo(80)); // 4th waits ~100 ms
    client.close();
  });

  test('convenience methods such as post and read are limited too', () async {
    final (:client, :times) = _build(bucketSize: 1, interval: const Duration(milliseconds: 100), tokensPerInterval: 1);

    await client.post(_uri('/a'), body: 'x');
    await client.read(_uri('/b'));

    expect(times, hasLength(2));
    expect(times[1], greaterThanOrEqualTo(80));
    client.close();
  });

  test('shouldThrottle can exempt requests', () async {
    final (:client, :times) = _build(
      bucketSize: 1,
      interval: const Duration(seconds: 10),
      tokensPerInterval: 1,
      shouldThrottle: (request) => !request.url.path.contains('health'),
    );

    await client.get(_uri('/a'));
    await client.get(_uri('/health'));
    await client.get(_uri('/health'));

    expect(times, hasLength(3));
    expect(times.last, lessThan(500));
    client.close();
  });

  test('bucketKey gives each host its own bucket', () async {
    final (:client, :times) = _build(
      bucketSize: 1,
      interval: const Duration(seconds: 10),
      tokensPerInterval: 1,
      bucketKey: (request) => request.url.host,
    );

    await client.get(_uri('/a', host: 'a.example.com'));
    await client.get(_uri('/a', host: 'b.example.com'));

    expect(times, hasLength(2));
    expect(times.last, lessThan(500));
    client.close();
  });

  test('throws RateLimitOverflowException when the queue is full', () async {
    final (:client, :times) = _build(bucketSize: 1, interval: const Duration(seconds: 10), tokensPerInterval: 1, maxQueueSize: 0);

    await client.get(_uri('/a'));

    await expectLater(client.get(_uri('/b')), throwsA(isA<RateLimitOverflowException>()));
    expect(times, hasLength(1));
    client.close();
  });

  test('an abortable request aborted while queued is never sent', () async {
    final (:client, :times) = _build(bucketSize: 1, interval: const Duration(seconds: 10), tokensPerInterval: 1);

    await client.get(_uri('/a'));

    final abort = Completer<void>();
    final future = client.send(http.AbortableRequest('GET', _uri('/b'), abortTrigger: abort.future));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    abort.complete();

    await expectLater(future, throwsA(isA<http.RequestAbortedException>()));
    expect(times, hasLength(1));
    client.close();
  });

  test('shared bucket is not disposed when the client is closed', () async {
    final bucket = TokenBucket(bucketSize: 2);
    final client = HttpRateLimiterClient.shared(bucket, inner: MockClient((_) async => http.Response('ok', 200)));

    client.close();

    expect(bucket.tryAcquire(), isTrue);
    bucket.dispose();
  });
}
