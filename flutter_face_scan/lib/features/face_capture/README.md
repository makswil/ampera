# `face_capture` feature

Portable TrueDepth capture + bake unit. The surrounding project is only a husk.

**Full project overview / export steps:** see root [`README.md`](../../../README.md).
**Native split guide:** [`ios/Runner/FaceTracking/README.md`](../../../ios/Runner/FaceTracking/README.md).

## Layout

```
domain/         Pure Dart (no Flutter / ARKit) — entities, validators, bake math
application/    BLoC state machine
data/           Platform channels, persistence, bake I/O
presentation/   Flutter UI
```

Dependency direction: `presentation → application → domain ← data`.

## Entry points

| Piece | Path |
| --- | --- |
| UI entry | `presentation/capture_page.dart` |
| Tracking port | `domain/services/face_tracking_service.dart` |
| Front channel | `data/arkit_face_tracking_service.dart` |
| Bake | `data/bake/session_baker.dart` |
| Persistence | `data/file_snapshot_repository.dart` |

Only channel names and `CapturePage` touch the outside world; everything else
is internal to this folder.
