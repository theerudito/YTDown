import 'dart:async';

Future<T> withOperationTimeout<T>(
  Future<T> operation, {
  required Duration duration,
  required String message,
  required void Function() onTimeout,
}) {
  return operation.timeout(
    duration,
    onTimeout: () {
      onTimeout();
      throw TimeoutException(message, duration);
    },
  );
}
