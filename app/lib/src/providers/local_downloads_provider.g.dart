// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'local_downloads_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(localDownloads)
final localDownloadsProvider = LocalDownloadsProvider._();

final class LocalDownloadsProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<LocalDownload>>,
          List<LocalDownload>,
          FutureOr<List<LocalDownload>>
        >
    with
        $FutureModifier<List<LocalDownload>>,
        $FutureProvider<List<LocalDownload>> {
  LocalDownloadsProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'localDownloadsProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$localDownloadsHash();

  @$internal
  @override
  $FutureProviderElement<List<LocalDownload>> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<List<LocalDownload>> create(Ref ref) {
    return localDownloads(ref);
  }
}

String _$localDownloadsHash() => r'd36057549aa5a39c5d621e324719e36991754281';
