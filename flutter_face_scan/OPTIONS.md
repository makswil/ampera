# Optionen & Alternativen — flutter_face_scan

Übersicht aller Capture-/Textur-Varianten: was implementiert ist, wie man es in
den Einstellungen aktiviert, und welche Alternativen noch offen sind.

Stand: Branch `feat/hires-photo`.

---

## Einstellungen öffnen

Zwei Sheets (nur wenn `kShowDevMenu == true`):

| Ort | Inhalt |
|---|---|
| **⚙ oben rechts** | **Scan:** Face distance, HUD, Mesh, Hi-Res-Foto, Manage scans |
| **🎚 neben Bake** | **Bake:** ml-wb, Löcher, Chin-up, View-dependent, Best-only |

- Für Produktion: `kShowDevMenu = false` in `debug_settings.dart`.
- Toggles sind **Laufzeit** (kein Rebuild), **nicht persistent**.

---

## 1. Implementiert — per Toggle umschaltbar

| Option | Was es tut | Sheet | Default | Wirkung |
|---|---|---|---|---|
| **Texturquelle** | ARKit-Video ↔ AVCapture Hi-Res | Scan ⚙ | **AUS** | AN = ~7 MP/Pose |
| **Face distance** | Ziel-Abstand Face-Frame | Scan ⚙ Slider | **25 cm** | Live; Oval skaliert |
| **Kalibrierungs-HUD** | Debug-Overlay | Scan ⚙ | via dart-define | Diagnose |
| **Mesh-Overlay** | Wireframe + Achse | Scan ⚙ | via dart-define | Vertex-Check |
| **Löcher füllen** | Augen-/Mund kappen | Bake 🎚 | **AN** | AUS = Löcher bleiben |
| **Chin-up für untere Fläche** | Kinn aus Chin-up-Pose | Bake 🎚 | **AN** | Nur statischer Pfad |
| **View-dependent Blend (n·v)** | Head-on Pose pro Punkt | Bake 🎚 | **AUS** | Re-bake |
| **View: best pose only** | Argmax statt Blend | Bake 🎚 | **AUS** | Nur mit view-dependent |
| **ml-wb white balance** | CoreML-WB vor Bake | Bake 🎚 | **AUS** | Re-bake; **schaltet Dart-Farbgain aus** (sonst würde Gain den Kelvin-Unterschied wieder löschen) |
| **ml-wb: match frontal** | Ziel = frontal-K vs 5600 K | Bake 🎚 | **AUS** (=5600 K) | Nur wenn ml-wb AN |

> Entfernt (redundant zu ml-wb): „match colours to frontal“ / „neutral colour target“.
> Ohne ml-wb bleibt beim View-dependent-Bake automatisch der Dart-Gain an frontal.

### Aktionen
- **Start | Bake** nebeneinander in der Guidance-Card; Bake-Settings via 🎚.
- **Share** oben rechts nach erfolgreichem Bake.
- **Manage saved scans** im Scan-Sheet.

> **Empfohlen scharf:** Hi-Res = **AN**, Fill holes = **AN**, optional ml-wb.
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
| **`--ml-wb`** | **ML-Weißabgleich:** schickt jede Pose vor dem Bake durch das `ml-wb`-PyTorch-Modell (`ml-wb/`, unangetastet) → alle Posen auf **einen** Weißpunkt (neutrales Tageslicht ~5600 K) normiert; entfernt Farb-/Belichtungsnähte robuster als der deterministische Dart-Gain (der zusätzlich obendrauf läuft). Braucht das lokale Python-venv (siehe unten). | CLI `dart run tool/bake_texture.dart <dir> --ml-wb` (kombinierbar mit `--view-dependent`) |
| **`--ml-wb-reference=frontal`** | Wie `--ml-wb`, aber Ziel-Weißpunkt = Weißabgleich der **frontalen** Aufnahme statt neutral | CLI `… --ml-wb-reference=frontal` |
| **`--ml-wb-python=<pfad>`** | Python-Interpreter für ml-wb überschreiben (Default: `tool/.venv-mlwb/bin/python`, sonst `python3`) | CLI `… --ml-wb --ml-wb-python=/pfad/zu/python` |
| **`--no-holes` / `--no-normals` / `--size`** | Bake-Varianten offline | CLI `tool/bake_texture.dart` |
| **ARKit `captureHighResolutionFrame`** | Hi-Res-Still aus der ARKit-Session (nur wenn Video-Format es unterstützt; bei Face-Tracking meist NICHT) | greift automatisch im ARKit-Pfad (Toggle „hi-res" = AUS), sonst Fallback auf Videoframe |

### ml-wb Setup (einmalig, nur für `--ml-wb` CLI **oder** App-CoreML-Export)
Der `ml-wb`-Ordner bleibt unangetastet; Brücken importieren ihn nur read-only.

**CLI (Mac):** Lokales Python-venv (Python 3.12, torch + scipy):

```bash
cd flutter_face_scan
python3.12 -m venv tool/.venv-mlwb
tool/.venv-mlwb/bin/python -m pip install \
  --index-url https://download.pytorch.org/whl/cpu torch
tool/.venv-mlwb/bin/python -m pip install pillow pyyaml numpy colour-science scipy
```

Danach `dart run tool/bake_texture.dart <dir> --ml-wb`.

**iOS-App (CoreML):** Modell einmal exportieren und ins Bundle legen (bereits unter
`ios/Runner/Models/MLWhiteBalance.mlpackage` wenn Export gelaufen ist):

```bash
tool/.venv-mlwb/bin/python -m pip install 'coremltools>=7'
tool/.venv-mlwb/bin/python tool/export_ml_wb_coreml.py
```

In der App: ⚙ → **ml-wb white balance** (+ optional **match frontal**), dann
„Re-bake texture". Schlägt CoreML fehl → Original-Stills + Dart-Gain.

### Tunables (wahrscheinlich am Gerät zu justieren)
| Parameter | Default | Ort | Bedeutung |
|---|---|---|---|
| `FacePose.up.targetPitch` | `22` | `face_pose.dart:17` | Kinn-hoch-Winkel der 4. Pose (steiler = weniger Nasen-Verdeckung, aber schwerer zu halten) |
| `targetDistanceMeters` | **`0.25`** (⚙-Slider 20–40 cm) | `pose_tolerance.dart` / Debug-Sheet | Face-Frame-Distanz; näher = mehr Gesichtspixel |
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
| ↳ Farb-/Belichtungs-Angleich zwischen Fotos | Jedes AVCapture-Foto hat eigene AE/AWB → Nähte beim Blenden; auf frontal normieren | **IMPLEMENTIERT** (Schritt C, `TextureBaker.poseGain` + optional **ml-wb CoreML** vor dem Bake, Toggle „ml-wb white balance") | — |
| ↳ Sichtbarkeits-/Tiefentest | Occlusion (Nase verdeckt Wange im Seitenfoto) sauber verwerfen | offen, nur falls Artefakte auftreten | mittel–hoch |
| **Per-Triangle Best-View** | Statt Blend pro Dreieck eine beste Pose wählen + an Grenzen federn (weniger Farbnähte, billig) | offen, guter Zwischenschritt | klein–mittel |
| **Volles MVS-Texturing** | Graph-Cut-Seams + Gradient-Domain-/Poisson-Blending (beste Qualität) | offen, aktuell overkill | hoch |
| **Depth-Normal-Map** | Normal-/Displacement-Map aus dem TrueDepth-Tiefenbild für Meso-Struktur (geom. Relief, keine Textur-Schärfe) | offen (Sekundär-Feature aus `TODO.md`) | mittel–hoch |

---

## Kurz-Referenz: Dateien

- Settings-Model: `lib/features/face_capture/presentation/debug/debug_settings.dart`
- Settings-UI: `lib/features/face_capture/presentation/capture_page.dart` (`_openScanSettings`, `_openBakeSettings`)
- Posen: `lib/features/face_capture/domain/entities/face_pose.dart`
- Validierung: `lib/features/face_capture/domain/logic/guided_pose_validator.dart`
- Achsen: `lib/features/face_capture/domain/constants/face_vertex_indices.dart`
- Regionen (generiert): `lib/features/face_capture/domain/constants/face_regions.g.dart`
- Bake: `lib/features/face_capture/data/bake/{session_baker,texture_baker}.dart`
- View-dependent Gewichtung: `lib/features/face_capture/domain/v3/view_weights.dart`
- Nativer Hi-Res-/Kamera-Code: `ios/Runner/AppDelegate.swift`
- Offline-Bake / Regionen-Tool: `tool/bake_texture.dart`, `tool/generate_face_regions.dart`
