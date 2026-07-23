# Optionen & Alternativen — flutter_face_scan

Übersicht aller Capture-/Textur-Varianten: was implementiert ist, wie man es in
den Einstellungen aktiviert, und welche Alternativen noch offen sind.

Stand: Branch `feat/hires-photo`.

---

## Einstellungen öffnen

Zahnrad-Icon **⚙ (oben rechts)** → Bottom-Sheet mit den Togglern.

- Nur sichtbar, wenn `kShowDevMenu == true`
  (`lib/features/face_capture/presentation/debug/debug_settings.dart:8`).
- Für einen Produktions-Build auf `false` setzen → Menü verschwindet.
- Toggles sind **Laufzeit** (kein Rebuild nötig), aber **nicht persistent**
  (nach App-Neustart zurück auf Default).

---

## 1. Implementiert — per Toggle umschaltbar

| Option | Was es tut | Toggle im ⚙-Sheet | Default | Wirkung |
|---|---|---|---|---|
| **Texturquelle** | ARKit-Video (stabil) ↔ AVCapture Hi-Res-Foto | **„Texture: AVCapture hi-res"** | **AUS** (ARKit-Video) | AN = 7 MP-Foto pro Pose (schärfer), ARKit wird pro Aufnahme kurz pausiert. AUS = ARKit-Videoframe (~1.5 MP, immer stabil) |
| **Löcher füllen** | Augen-/Mundlöcher kappen + texturieren | **„Fill eye/mouth holes"** | **AN** | AUS = ARKit-Löcher bleiben im Modell |
| **Chin-up für untere Fläche** | Kinn/Unterkiefer aus der Chin-up-Pose statt frontal | **„Chin-up for lower face"** | **AN** | AUS = nur frontal (ausschalten, falls die Nase geistert). Wirkt nach „Re-bake texture" auch auf die letzte Session. Nur im **statischen** (regionsbasierten) Pfad relevant |
| **View-dependent Blend (n·v)** | Pro Oberflächenpunkt das Foto gewichten, das die Fläche am direktesten (head-on) gesehen hat; ersetzt die statischen Tabellen. Mit Guards: frontal = mittleres Band, Turn-Posen = jeweils ihre Hälfte, Chin-up = untere Hälfte | **„View-dependent blend (n·v)"** | **AUS** | AN = adaptive Quellenauswahl (A/B gegen aktuell). „Re-bake texture" anwenden. Guards verhindern Übersprechen über die Symmetrieachse |
| **View: best pose only** | Pro Texel nur die **beste** Pose (argmax `n·v`) statt gewichtetem Mittel → maximal scharf, aber sichtbare Nähte am Gewinner-Wechsel | **„View: best pose only (sharper)"** | **AUS** (gewichtet mischen) | Nur bei aktivem view-dependent. AN = keine Vermischung (schärfer). Nähte durch Farbangleich mildern |
| **View: Farben an frontal angleichen** | Jede Pose per Kanal-Gain auf die frontale Belichtung/Weißabgleich normieren (gemessen im Überlappungsbereich) → keine Belichtungs-/Farbnähte | **„View: match colours to frontal"** | **AN** | Nur bei aktivem view-dependent. Essenziell für best-only. AUS = Rohfarben je Pose |
| **View: neutrales Farbziel** | Referenz-Modus für den Farbausgleich: alle Posen (inkl. frontal) auf ihren **gemeinsamen Mittelwert** normieren statt auf frontal → keine privilegierte Pose | **„View: neutral colour target"** | **AUS** (= an frontal) | Braucht „match colours" AN. AN = neutral/„default"-artig; AUS = frontal als Referenz. `ml-wb` selbst läuft nicht im Isolate (Python) |
| **Kalibrierungs-HUD** | Debug-Overlay (Winkel, hi-res cap, Auflösungen) | **„Calibration HUD"** | via `--dart-define CAPTURE_DEBUG_HUD` | Reines Diagnose-Overlay |
| **Mesh-Overlay** | Grünes Wireframe + rote Symmetrieachs-Punkte | **„Face mesh overlay"** | via `--dart-define FACE_MESH_OVERLAY` | Verifiziert Vertex-Tabellen live |

### Aktionen im selben Sheet (keine Varianten)
- **„Re-bake texture"** — backt die letzte gespeicherte Session mit den aktuellen
  Einstellungen neu (z.B. nach Umschalten von „Fill holes"), ohne neu zu scannen.
- **„Manage saved scans"** — gespeicherte Sessions ansehen/löschen.

> **Empfohlene Variante für schärfste Textur:** „Texture: AVCapture hi-res" = **AN**,
> „Fill eye/mouth holes" = **AN**.

---

## 2. Implementiert — immer aktiv (kein Toggle)

Diese laufen fest mit; zum Deaktivieren wäre eine Code-Änderung nötig.

| Feature | Beschreibung | Ort | Deaktivieren |
|---|---|---|---|
| **4. Pose „Chin up"** | Zusätzliche Kinn-hoch-Aufnahme; liefert die untere Gesichtsfläche (Kinn, Unterkiefer) frontal statt verzerrt | `face_pose.dart` (`FacePose.up`) | `up` aus dem Enum entfernen (oder Bake-Nutzung via Toggle „Chin-up for lower face" aus) |
| **Untere-Region-Blend** | Untere Fläche zieht per `downWeight` (aus horizontaler Achse) aus der Chin-up-Aufnahme; Wangen/Kiefer bleiben bei Links/Rechts. Dead-Zone unter der Achse hält die (untere) Nase frontal → kein „Nasen-Ghost" | `session_baker.dart` (`_computeDownWeights`), `texture_baker.dart` | Toggle „Chin-up for lower face" (Abschnitt 1) |
| **Kamera-Prewarm** | AVCapture-Kamera wird beim Scan-Start vorgewärmt → kein Freeze beim ersten Foto | `ios/Runner/AppDelegate.swift` (`prewarmPhotoSession`) | — |
| **AE/AWB-Settle** | Wartet vor jedem Hi-Res-Foto auf Belichtung/Weißabgleich → kein „Nacht-Blau" | `ios/Runner/AppDelegate.swift` (`capturePhoto`) | — |
| **Foto horizontal geflippt** | AVCapture-Front-Foto an ARKit-Konvention angeglichen (Leberflecke korrekte Seite) | `ios/Runner/AppDelegate.swift` (`captureHiResStill`) | — |
| **Textur-Auflösung = Original** | Atlas = Quell-Foto-Auflösung (kein manuelles Setting mehr) | `capture_page.dart:247` (`textureSize: 0`) | Wert ändern |

---

## 3. Implementiert — nur im Code / CLI (keine App-UI)

| Option | Was es tut | Wie aktivieren |
|---|---|---|
| **`flipSides`** | Vertauscht Links-/Rechts-Quellfoto (falls Wangen gespiegelt wirken) | Bake-Param `flipSides: true` in `SessionTextureBaker.bake` **oder** CLI `dart run tool/bake_texture.dart <dir> --flip` |
| **`--view-dependent`** | n·v-Blend offline backen (wie der App-Toggle) | CLI `dart run tool/bake_texture.dart <dir> --view-dependent` |
| **`--best`** | Mit `--view-dependent`: best-only statt gewichtetem Mittel | CLI `dart run tool/bake_texture.dart <dir> --view-dependent --best` |
| **`--no-color-match`** | Mit `--view-dependent`: Farbangleich der Posen an frontal aus | CLI `dart run tool/bake_texture.dart <dir> --view-dependent --no-color-match` |
| **`--wb-neutral`** | Mit `--view-dependent`: alle Posen auf gemeinsamen Mittelwert statt frontal | CLI `dart run tool/bake_texture.dart <dir> --view-dependent --wb-neutral` |
| **`--no-holes` / `--no-normals` / `--size`** | Bake-Varianten offline | CLI `tool/bake_texture.dart` |
| **ARKit `captureHighResolutionFrame`** | Hi-Res-Still aus der ARKit-Session (nur wenn Video-Format es unterstützt; bei Face-Tracking meist NICHT) | greift automatisch im ARKit-Pfad (Toggle „hi-res" = AUS), sonst Fallback auf Videoframe |

### Tunables (wahrscheinlich am Gerät zu justieren)
| Parameter | Default | Ort | Bedeutung |
|---|---|---|---|
| `FacePose.up.targetPitch` | `22` | `face_pose.dart:17` | Kinn-hoch-Winkel der 4. Pose (steiler = weniger Nasen-Verdeckung, aber schwerer zu halten) |
| `_downStartFraction` | `0.25` | `session_baker.dart` | Dead-Zone unter der Achse (größer = Nase sicherer frei, weniger Unter-Nasen-Abdeckung) — nur statischer Pfad |
| `_downFullFraction` | `0.60` | `session_baker.dart` | Ab hier volle Chin-up-Gewichtung Richtung Kinn — nur statischer Pfad |
| `kDefaultFacingExponent` | `3` | `view_weights.dart` | n·v-Schärfe `k` (höher = head-on-Pose dominiert stärker; 2–4) |
| `kDefaultMinFacing` | `0.2` | `view_weights.dart` | Mindest-`n·v`; darunter Sample verworfen (streifend/verzerrt) |
| `kFrontalCenterFraction` | `0.5` | `view_weights.dart` | Frontal-Band = mittlere 50 % der Gesichtsbreite (Rest → Turn-Posen) |
| AE/AWB-Timeout | `0.8 s` | `AppDelegate.swift` (`capturePhoto`) | Max. Wartezeit auf Belichtung/Weißabgleich |
| `pitchToleranceDegrees` u.a. | `5` | `pose_tolerance.dart` | Akzeptanz-Toleranzen aller Posen |

---

## 4. Alternativen — noch NICHT implementiert

| Alternative | Idee | Status | Aufwand |
|---|---|---|---|
| **Normalen-basiertes Blending** (view-dependent) | Pro Vertex jedes Foto nach `n·v` gewichten (wie head-on die Kamera die Fläche sah); ersetzt die statischen `sideWeight`/`downWeight`-Tabellen und wählt automatisch die beste Aufnahme (Chin-up gewinnt unter der Nase von selbst) | **IMPLEMENTIERT** (Toggle „View-dependent blend (n·v)", Abschnitt 1) — Schritt A+B | — |
| ↳ Symmetrieachs-Guard | `n·v`-Gewicht einer Seiten-Pose jenseits der Mittelachse hart auf 0 → kein Übersprechen | **IMPLEMENTIERT** (`PoseGuard` in `view_weights.dart`: frontal=mittleres Band, Turn=Hälfte, Chin-up=untere Hälfte, + Mindest-Winkel) | — |
| ↳ Farb-/Belichtungs-Angleich zwischen Fotos | Jedes AVCapture-Foto hat eigene AE/AWB → Nähte beim Blenden; auf frontal normieren | **IMPLEMENTIERT** (Schritt C, `TextureBaker.poseGain`: per-Kanal-Gain über Überlappung; Toggle „View: match colours to frontal"). `ml-wb` = separates Python-Modell, nicht im Isolate → bewusst deterministischer Gain-Ansatz | — |
| ↳ Sichtbarkeits-/Tiefentest | Occlusion (Nase verdeckt Wange im Seitenfoto) sauber verwerfen | offen, nur falls Artefakte auftreten | mittel–hoch |
| **Per-Triangle Best-View** | Statt Blend pro Dreieck eine beste Pose wählen + an Grenzen federn (weniger Farbnähte, billig) | offen, guter Zwischenschritt | klein–mittel |
| **Volles MVS-Texturing** | Graph-Cut-Seams + Gradient-Domain-/Poisson-Blending (beste Qualität) | offen, aktuell overkill | hoch |
| **Depth-Normal-Map** | Normal-/Displacement-Map aus dem TrueDepth-Tiefenbild für Meso-Struktur (geom. Relief, keine Textur-Schärfe) | offen (Sekundär-Feature aus `TODO.md`) | mittel–hoch |

---

## Kurz-Referenz: Dateien

- Settings-Model: `lib/features/face_capture/presentation/debug/debug_settings.dart`
- Settings-UI: `lib/features/face_capture/presentation/capture_page.dart` (`_openDebugSheet`)
- Posen: `lib/features/face_capture/domain/entities/face_pose.dart`
- Validierung: `lib/features/face_capture/domain/logic/guided_pose_validator.dart`
- Achsen: `lib/features/face_capture/domain/constants/face_vertex_indices.dart`
- Regionen (generiert): `lib/features/face_capture/domain/constants/face_regions.g.dart`
- Bake: `lib/features/face_capture/data/bake/{session_baker,texture_baker}.dart`
- View-dependent Gewichtung: `lib/features/face_capture/domain/v3/view_weights.dart`
- Nativer Hi-Res-/Kamera-Code: `ios/Runner/AppDelegate.swift`
- Offline-Bake / Regionen-Tool: `tool/bake_texture.dart`, `tool/generate_face_regions.dart`
