import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:meta/meta.dart';

import 'exceptions.dart';

/// A token bucket that hands out permission to proceed at a controlled rate.
///
/// The bucket holds up to [bucketSize] tokens and starts full. Tokens are
/// added continuously at a rate of [tokensPerInterval] every [interval]
/// (never exceeding [bucketSize]). Every unit of work consumes tokens by
/// calling [acquire] or [tryAcquire].
///
/// This allows short **bursts** of up to [bucketSize] operations while keeping
/// the **sustained** rate at `tokensPerInterval / interval`.
///
/// With the defaults (10 tokens, 2 tokens every 500 ms) you get a burst of 10
/// operations and a sustained rate of 4 operations per second.
///
/// When no token is available, [acquire] waits. Waiting callers are served in
/// first-in-first-out order, so a cheap request cannot overtake an expensive
/// one that arrived earlier.
///
/// ```dart
/// final bucket = TokenBucket(bucketSize: 5, tokensPerInterval: 1);
///
/// await bucket.acquire();
/// doWork();
/// ```
///
/// Call [dispose] when the bucket is no longer needed to release its timer.
class TokenBucket {
  /// Creates a token bucket.
  ///
  /// * [bucketSize] is the maximum number of tokens, and therefore the largest
  ///   possible burst. Must be greater than zero.
  /// * [interval] and [tokensPerInterval] define the refill rate: that many
  ///   tokens are added per interval. Both must be greater than zero.
  /// * [maxQueueSize] limits how many callers may wait at the same time. When
  ///   the limit is reached, [acquire] fails with a
  ///   [RateLimitOverflowException]. `null` (the default) means unlimited, and
  ///   `0` means callers never wait (fail fast).
  TokenBucket({
    this.bucketSize = 10,
    this.interval = const Duration(milliseconds: 500),
    this.tokensPerInterval = 2,
    this.maxQueueSize,
    @visibleForTesting Duration Function()? clock,
  })  : assert(bucketSize > 0, 'bucketSize must be greater than zero'),
        assert(interval > Duration.zero, 'interval must be greater than zero'),
        assert(tokensPerInterval > 0,
            'tokensPerInterval must be greater than zero'),
        assert(maxQueueSize == null || maxQueueSize >= 0,
            'maxQueueSize must not be negative'),
        _tokens = bucketSize.toDouble(),
        _tokensPerMicrosecond = tokensPerInterval / interval.inMicroseconds {
    if (clock != null) {
      _clock = clock;
    } else {
      final stopwatch = Stopwatch()..start();
      _clock = () => stopwatch.elapsed;
    }
    _lastRefill = _clock();
  }

  /// Maximum number of tokens the bucket can hold (the largest burst).
  final int bucketSize;

  /// The period after which [tokensPerInterval] tokens are added.
  final Duration interval;

  /// How many tokens are added every [interval].
  final int tokensPerInterval;

  /// The maximum number of callers allowed to wait for a token, or `null` if
  /// unlimited.
  final int? maxQueueSize;

  /// Tolerance for floating point rounding when comparing token counts.
  static const double _epsilon = 1e-9;

  final double _tokensPerMicrosecond;
  final Queue<_Waiter> _queue = Queue<_Waiter>();

  late final Duration Function() _clock;
  late Duration _lastRefill;
  double _tokens;
  Timer? _timer;
  bool _disposed = false;

  /// The number of tokens currently available, including fractions.
  double get availableTokens {
    _refill();
    return _tokens;
  }

  /// The number of callers currently waiting for a token.
  int get pending => _queue.length;

  /// Waits until [tokens] tokens are available, then consumes them.
  ///
  /// Completes immediately if enough tokens are available and nobody is
  /// waiting ahead. Otherwise the caller is queued.
  ///
  /// If [cancelSignal] completes while the caller is still queued, the caller
  /// is removed from the queue without consuming tokens and the returned
  /// future fails with a [RateLimitCancelledException].
  ///
  /// The returned future fails with:
  ///
  /// * [RateLimitOverflowException] if the queue is full (see [maxQueueSize]),
  /// * [RateLimitCancelledException] if cancelled or disposed while waiting,
  /// * [StateError] if the bucket was already disposed.
  ///
  /// Throws an [ArgumentError] if [tokens] is not between 1 and [bucketSize]:
  /// a larger request could never be satisfied.
  Future<void> acquire({int tokens = 1, Future<Object?>? cancelSignal}) {
    _checkCost(tokens);
    if (_disposed) {
      return Future<void>.error(StateError('TokenBucket was disposed.'));
    }

    _refill();
    if (_queue.isEmpty && _tokens + _epsilon >= tokens) {
      _consume(tokens);
      return Future<void>.value();
    }

    final limit = maxQueueSize;
    if (limit != null && _queue.length >= limit) {
      return Future<void>.error(RateLimitOverflowException(limit));
    }

    final waiter = _Waiter(tokens);
    _queue.addLast(waiter);

    void onCancel() {
      if (_queue.remove(waiter)) {
        waiter.completer.completeError(const RateLimitCancelledException());
        // The head of the queue may have changed, so recompute the wake-up.
        _drain();
      }
    }

    cancelSignal?.then((_) => onCancel(), onError: (Object _) => onCancel());

    _drain();
    return waiter.completer.future;
  }

  /// Consumes [tokens] tokens if they are available right now.
  ///
  /// Returns `true` on success. Never waits. Returns `false` if there are not
  /// enough tokens, or if other callers are already queued (to keep the
  /// first-in-first-out ordering fair).
  bool tryAcquire({int tokens = 1}) {
    _checkCost(tokens);
    if (_disposed || _queue.isNotEmpty) return false;
    _refill();
    if (_tokens + _epsilon < tokens) return false;
    _consume(tokens);
    return true;
  }

  /// Releases the internal timer and fails all waiting callers with a
  /// [RateLimitCancelledException].
  ///
  /// After disposal, [acquire] fails with a [StateError] and [tryAcquire]
  /// returns `false`. Calling [dispose] more than once is safe.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    while (_queue.isNotEmpty) {
      _queue.removeFirst().completer.completeError(
            const RateLimitCancelledException('TokenBucket was disposed.'),
          );
    }
  }

  void _checkCost(int tokens) {
    if (tokens < 1 || tokens > bucketSize) {
      throw ArgumentError.value(
        tokens,
        'tokens',
        'must be between 1 and bucketSize ($bucketSize)',
      );
    }
  }

  void _consume(int tokens) {
    _tokens = math.max(0, _tokens - tokens);
  }

  /// Adds the tokens earned since the last refill.
  void _refill() {
    final now = _clock();
    final elapsedMicros = (now - _lastRefill).inMicroseconds;
    if (elapsedMicros <= 0) return;
    _tokens = math.min(
      bucketSize.toDouble(),
      _tokens + elapsedMicros * _tokensPerMicrosecond,
    );
    _lastRefill = now;
  }

  /// Serves as many queued callers as possible, then schedules a wake-up for
  /// the moment the next one can be served.
  void _drain() {
    _timer?.cancel();
    _timer = null;
    if (_disposed) return;

    _refill();
    while (_queue.isNotEmpty && _tokens + _epsilon >= _queue.first.tokens) {
      final waiter = _queue.removeFirst();
      _consume(waiter.tokens);
      waiter.completer.complete();
    }

    if (_queue.isEmpty) return;

    final missing = _queue.first.tokens - _tokens;
    final waitMicros = (missing / _tokensPerMicrosecond).ceil();
    _timer = Timer(Duration(microseconds: math.max(waitMicros, 1)), _drain);
  }
}

class _Waiter {
  _Waiter(this.tokens);

  final int tokens;
  final Completer<void> completer = Completer<void>();
}
