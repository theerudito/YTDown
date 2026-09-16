import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ydown/operation_timeout.dart';

void main() {
  test('returns an operation result before the deadline', () async {
    var timedOut = false;

    final result = await withOperationTimeout(
      Future.value('ready'),
      duration: const Duration(seconds: 1),
      message: 'too slow',
      onTimeout: () => timedOut = true,
    );

    expect(result, 'ready');
    expect(timedOut, isFalse);
  });

  test('runs timeout cleanup and reports the phase message', () async {
    var timedOut = false;

    final result = withOperationTimeout(
      Completer<void>().future,
      duration: Duration.zero,
      message: 'stream discovery timed out',
      onTimeout: () => timedOut = true,
    );

    await expectLater(
      result,
      throwsA(
        isA<TimeoutException>().having(
          (error) => error.message,
          'message',
          'stream discovery timed out',
        ),
      ),
    );
    expect(timedOut, isTrue);
  });
}
