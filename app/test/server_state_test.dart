// ServerState.copyWith: the error field must be clearable (start() opens
// with copyWith(error: null), which was a silent no-op before the sentinel).

import 'package:flutter_test/flutter_test.dart';
import 'package:landir_app/src/providers/server_provider.dart';

void main() {
  test('copyWith(error: null) clears the error', () {
    const state = ServerState(error: 'bind failed');
    expect(state.copyWith(error: null).error, isNull);
  });

  test('copyWith preserves the error when the argument is not given', () {
    const state = ServerState(error: 'bind failed');
    expect(state.copyWith(running: true).error, 'bind failed');
  });

  test('copyWith sets a new error', () {
    const state = ServerState();
    expect(state.copyWith(error: 'x').error, 'x');
  });
}
