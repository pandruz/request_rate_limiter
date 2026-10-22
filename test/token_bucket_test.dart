import 'dart:async';

import 'package:request_rate_limiter/request_rate_limiter.dart';
import 'package:test/test.dart';

void main() {
  group('TokenBucket (manual clock)', () {
    late Duration now;
    late TokenBucket bucket;

    setUp(() {
      now = Duration.zero;
      bucket = TokenBucket(bucketSize: 4, interval: const Duration(seconds: 1), tokensPerInterval: 2, clock: () => now);
    });

    tearDown(() => bucket.dispose());

    test('starts full', () {
      expect(bucket.availableTokens, 4);
    });

    test('allows a burst of bucketSize, then refuses', () {
      for (var i = 0; i < 4; i++) {
        expect(bucket.tryAcquire(), isTrue, reason: 'token $i');
      }
      expect(bucket.tryAcquire(), isFalse);
    });

    test('refills at tokensPerInterval / interval', () {
      bucket.tryAcquire(tokens: 4);
      expect(bucket.tryAcquire(), isFalse);

      now += const Duration(milliseconds: 500); // +1 token
      expect(bucket.availableTokens, closeTo(1, 1e-6));
      expect(bucket.tryAcquire(), isTrue);
      expect(bucket.tryAcquire(), isFalse);
    });

    test('never exceeds bucketSize', () {
      now += const Duration(hours: 1);
      expect(bucket.availableTokens, 4);
    });

    test('tryAcquire supports a cost', () {
      expect(bucket.tryAcquire(tokens: 3), isTrue);
      expect(bucket.tryAcquire(tokens: 2), isFalse);
      expect(bucket.tryAcquire(tokens: 1), isTrue);
    });

    test('rejects invalid costs', () {
      expect(() => bucket.tryAcquire(tokens: 0), throwsArgumentError);
      expect(() => bucket.tryAcquire(tokens: 5), throwsArgumentError);
      expect(() => bucket.acquire(tokens: 5), throwsArgumentError);
    });
  });

  group('TokenBucket (real time)', () {
    test('acquire completes immediately while tokens remain', () async {
      final bucket = TokenBucket(bucketSize: 3, interval: const Duration(seconds: 10), tokensPerInterval: 1);
      final sw = Stopwatch()..start();
      await bucket.acquire();
      await bucket.acquire();
      await bucket.acquire();
      expect(sw.elapsedMilliseconds, lessThan(100));
      bucket.dispose();
    });

    test('acquire waits for a refill when empty', () async {
      final bucket = TokenBucket(bucketSize: 1, interval: const Duration(milliseconds: 100), tokensPerInterval: 1);
      await bucket.acquire();
      final sw = Stopwatch()..start();
      await bucket.acquire();
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(80));
      bucket.dispose();
    });

    test('serves waiters in FIFO order', () async {
      final bucket = TokenBucket(bucketSize: 1, interval: const Duration(milliseconds: 50), tokensPerInterval: 1);
      await bucket.acquire();

      final order = <int>[];
      await Future.wait([for (var i = 0; i < 4; i++) bucket.acquire().then((_) => order.add(i))]);
      expect(order, [0, 1, 2, 3]);
      bucket.dispose();
    });

    test('fails with RateLimitOverflowException when the queue is full', () async {
      final bucket = TokenBucket(bucketSize: 1, interval: const Duration(seconds: 10), tokensPerInterval: 1, maxQueueSize: 1);
      await bucket.acquire(); // consumes the only token
      final queued = bucket.acquire(); // fills the queue
      expect(bucket.pending, 1);

      await expectLater(bucket.acquire(), throwsA(isA<RateLimitOverflowException>()));

      bucket.dispose();
      await expectLater(queued, throwsA(isA<RateLimitCancelledException>()));
    });

    test('maxQueueSize 0 fails fast', () async {
      final bucket = TokenBucket(bucketSize: 1, interval: const Duration(seconds: 10), tokensPerInterval: 1, maxQueueSize: 0);
      await bucket.acquire();
      await expectLater(bucket.acquire(), throwsA(isA<RateLimitOverflowException>()));
      bucket.dispose();
    });

    test('cancelSignal removes the waiter without consuming a token', () async {
      final bucket = TokenBucket(bucketSize: 1, interval: const Duration(milliseconds: 100), tokensPerInterval: 1);
      await bucket.acquire();

      final cancel = Completer<void>();
      final waiting = bucket.acquire(cancelSignal: cancel.future);
      expect(bucket.pending, 1);

      cancel.complete();
      await expectLater(waiting, throwsA(isA<RateLimitCancelledException>()));
      expect(bucket.pending, 0);

      // The next caller still gets the very next token.
      final sw = Stopwatch()..start();
      await bucket.acquire();
      expect(sw.elapsedMilliseconds, lessThan(200));
      bucket.dispose();
    });

    test('dispose fails waiters and later calls', () async {
      final bucket = TokenBucket(bucketSize: 1, interval: const Duration(seconds: 10), tokensPerInterval: 1);
      await bucket.acquire();
      final waiting = bucket.acquire();

      bucket.dispose();
      bucket.dispose(); // idempotent

      await expectLater(waiting, throwsA(isA<RateLimitCancelledException>()));
      await expectLater(bucket.acquire(), throwsA(isA<StateError>()));
      expect(bucket.tryAcquire(), isFalse);
    });
  });
}
