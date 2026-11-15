// MethodChannel definitions for native Android/iOS capabilities.

import 'package:flutter/services.dart';

/// Channel for writing received files to MediaStore.Downloads on Android.
const MethodChannel mediaStoreChannel = MethodChannel('landir/media_store');

/// Channel for LocalOnlyHotspot on Android API 30+.
const MethodChannel hotspotChannel = MethodChannel('landir/hotspot');
