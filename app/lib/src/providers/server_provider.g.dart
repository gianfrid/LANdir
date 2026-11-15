// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'server_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// Picks the FileSink for the current platform.

@ProviderFor(fileSink)
final fileSinkProvider = FileSinkProvider._();

/// Picks the FileSink for the current platform.

final class FileSinkProvider
    extends
        $FunctionalProvider<AsyncValue<FileSink>, FileSink, FutureOr<FileSink>>
    with $FutureModifier<FileSink>, $FutureProvider<FileSink> {
  /// Picks the FileSink for the current platform.
  FileSinkProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'fileSinkProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$fileSinkHash();

  @$internal
  @override
  $FutureProviderElement<FileSink> $createElement($ProviderPointer pointer) =>
      $FutureProviderElement(pointer);

  @override
  FutureOr<FileSink> create(Ref ref) {
    return fileSink(ref);
  }
}

String _$fileSinkHash() => r'15b80f0094e468dc4210079b07475f276bbacfcc';

/// The running LandirServer instance (kept alive while running).

@ProviderFor(ServerController)
final serverControllerProvider = ServerControllerProvider._();

/// The running LandirServer instance (kept alive while running).
final class ServerControllerProvider
    extends $NotifierProvider<ServerController, ServerState> {
  /// The running LandirServer instance (kept alive while running).
  ServerControllerProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'serverControllerProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$serverControllerHash();

  @$internal
  @override
  ServerController create() => ServerController();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(ServerState value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<ServerState>(value),
    );
  }
}

String _$serverControllerHash() => r'02357852e4e924ab69d69ec758194a6c6af8d6a7';

/// The running LandirServer instance (kept alive while running).

abstract class _$ServerController extends $Notifier<ServerState> {
  ServerState build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<ServerState, ServerState>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<ServerState, ServerState>,
              ServerState,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}
