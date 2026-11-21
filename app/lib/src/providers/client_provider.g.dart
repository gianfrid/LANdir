// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'client_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(ClientController)
final clientControllerProvider = ClientControllerProvider._();

final class ClientControllerProvider
    extends $NotifierProvider<ClientController, ClientState> {
  ClientControllerProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'clientControllerProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$clientControllerHash();

  @$internal
  @override
  ClientController create() => ClientController();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(ClientState value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<ClientState>(value),
    );
  }
}

String _$clientControllerHash() => r'0e3f4c84c097567b7707da09494f4c45f4592b79';

abstract class _$ClientController extends $Notifier<ClientState> {
  ClientState build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<ClientState, ClientState>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<ClientState, ClientState>,
              ClientState,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}
