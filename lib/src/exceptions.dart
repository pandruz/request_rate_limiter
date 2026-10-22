/// Base class for all errors thrown by this package.
class RateLimitException implements Exception {
  /// Creates a [RateLimitException] with a human readable [message].
  const RateLimitException(this.message);

  /// A description of what went wrong.
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// Thrown when a request cannot be queued because the queue is full.
///
/// This only happens when a `maxQueueSize` is configured. Without a limit,
/// requests always wait for their turn.
class RateLimitOverflowException extends RateLimitException {
  /// Creates a [RateLimitOverflowException] for a queue limited to
  /// [maxQueueSize] waiting requests.
  RateLimitOverflowException(this.maxQueueSize)
      : super('Rate limiter queue is full (maxQueueSize: $maxQueueSize).');

  /// The queue limit that was exceeded.
  final int maxQueueSize;
}

/// Thrown when a waiting request is removed from the queue before it
/// received a token, either because it was cancelled or because the bucket
/// was disposed.
class RateLimitCancelledException extends RateLimitException {
  /// Creates a [RateLimitCancelledException].
  const RateLimitCancelledException([
    super.message = 'Request left the rate limiter queue before being sent.',
  ]);
}
