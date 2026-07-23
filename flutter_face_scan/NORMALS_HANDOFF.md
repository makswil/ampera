# Handoff — View-dependent (normal-based) texture baking

Ziel: Die **statische regionsbasierte** Quellenauswahl beim Textur-Bake durch
**view-dependent texture mapping** ersetzen — pro Oberflächenpunkt das Foto
gewichten, das die Fläche am direktesten (head-on) gesehen hat (`n·v`).

Dieses Dokument ist ein Self-contained-Briefing. Alle Pfade relativ zu
`/Users/maxwilhelm/AmperaProjects/ampera/flutter_face_scan`.
Branch: `feat/hires-photo` (uncommittete Änderungen vorhanden).

---

## STATUS (Schritt A + B umgesetzt)

Der view-dependent Pfad ist implementiert und hinter dem Toggle **„View-dependent
blend (n·v)"** (⚙-Sheet, Default AUS → A/B). Ebenfalls im CLI-Tool via
`--view-dependent`.

- Reine, getestete Gewichtungs-Mathematik: `domain/v3/view_weights.dart`
  (`viewFacingWeights`, `poseAllowMask`, `computeGuardFrame`, `PoseGuard`).
  Tests: `test/domain/view_weights_test.dart`.
- `BakePose` trägt jetzt `viewMatrix` + `faceTransform`.
- `TextureBaker.bakeViewDependent(poses, uvs, triangles, size, blend)` verrechnet
  eine Liste `WeightedPose` (Pose + per-Vertex-Gewicht) pro Texel: `blend=true`
  (Default) = gewichtetes Mittel über die abdeckenden Posen (weiche Nähte);
  `blend=false` = **best-only** (argmax `n·v`, keine Vermischung → maximal scharf,
  aber Nähte am Gewinner-Wechsel). Fallback = erste (frontale) Pose. Toggle:
  „View: best pose only (sharper)" bzw. CLI `--best`.
- Orchestrierung: `session_baker.dart:_bakeViewDependent` (im Isolate) und
  spiegelgleich `tool/bake_texture.dart:_bakeViewDependent`.
- **Guards (Schritt B, umgesetzt):**
  - frontal → nur mittleres Band (`kFrontalCenterFraction = 0.5` der Breite),
  - Turn-links-Pose → rechte Hälfte (positives lokales X),
  - Turn-rechts-Pose → linke Hälfte (negatives lokales X),
  - Chin-up-Pose → untere Hälfte (unter der horizontalen Achse),
  - Mindest-Winkel `kDefaultMinFacing = 0.2`, Schärfe `kDefaultFacingExponent = 3`.
- Der **statische** Pfad (`_pickSide`/`sideWeight`/`downWeight`, `chinUpLowerFace`)
  bleibt als Fallback vollständig erhalten.

**Schritt C (Farbangleich) umgesetzt:** `TextureBaker.poseGain` berechnet pro
Nicht-Frontal-Pose einen per-Kanal-RGB-Gain, der die Pose im Überlappungsbereich
(beide Gewichte > Schwelle) auf die frontale Belichtung/Weißabgleich normiert
(mittelwertbasiert, geclamped `[0.5, 2.0]`, Fallback `[1,1,1]` bei zu wenig
Überlappung). Angewandt in beiden Modi (weighted + best-only). Toggle „View:
match colours to frontal" (Default AN) bzw. CLI `--no-color-match`. Hinweis:
`ml-wb` (commit 98b1e53) ist ein separates **Python-UNet** und läuft NICHT im
Dart-Bake-Isolate → daher der deterministische Gain-Ansatz statt ml-wb.

Zwei Farb-Referenz-Modi (Toggle „View: neutral colour target" / CLI
`--wb-neutral`): **frontal** (Default, `TextureBaker.poseGain` über Überlappung)
oder **neutral** (`session_baker._poseGains` + `TextureBaker.poseMeanColor`/
`gainToTarget`: alle Posen inkl. frontal auf ihren gemeinsamen Mittelwert). Der
neutral-Modus ist der deterministische In-App-Ersatz für „alle auf ml-wb-Default"
(echtes ml-wb wäre ein Offline-Python-Preprocessing der 4 JPEGs, kein Isolate-Bake).

**Offen:** optional D (Occlusion/Tiefentest); ggf. Mean+Std- statt reinem
Gain-Match, falls Nähte bleiben; optional ml-wb offline im Tool verdrahten.

---

## 1. Warum

Aktuell wird die Textur aus mehreren Posen zusammengesetzt, indem pro Vertex per
**fester Tabelle** entschieden wird, welches Foto beiträgt (Links/Rechts über
X-Split, unten über eine horizontale Achse). Nachteile: nicht adaptiv,
handgetunte Tabellen, Ghosting/Unschärfe an Blend-Grenzen, Nase wird bei der
Chin-up-Pose doppelt (Verdeckung). `n·v`-Gewichtung löst das prinzipiell besser
und wählt automatisch die beste Aufnahme pro Fläche.

---

## 2. Ist-Zustand der Pipeline (Fakten)

### Posen
`lib/features/face_capture/domain/entities/face_pose.dart`
- `FacePose { frontal(yaw0,pitch0), left40(yaw35), right40(yaw-35), up(pitch22) }`
- `captureSequence == FacePose.values` (Reihenfolge = Aufnahmereihenfolge).

### Capture-Flow
- Hold-Logik (2,5 s) in `application/capture_bloc.dart`.
- Pro fertiger Pose grabbt `presentation/capture_page.dart:_grabStill` einen
  Still via `data/arkit_face_tracking_service.dart:captureStill(hiRes:)`.
- Native `ios/Runner/AppDelegate.swift`: ARKit-Face-Tracking + AVCapture-Hi-Res
  (pause ARKit → 7 MP-Foto → resume), Prewarm, AE/AWB-Settle, Horizontal-Flip.
  Liefert Still-Map: `jpeg,width,height,viewMatrix,projectionMatrix,faceTransform`.
- `StillCapture` (`domain/entities/still_capture.dart`): `bytes,width,height,
  viewMatrix,projectionMatrix,faceTransform` (alle Matrizen column-major,
  `vector_math_64`).

### Bake
- Einstieg: `data/bake/session_baker.dart:SessionTextureBaker.bake(...)`
  → Isolate-Funktion `_runBake` → `data/bake/texture_baker.dart:TextureBaker.bake`.
- `_PoseInput` (session_baker) trägt pro Pose: `jpeg, vertices(flat),
  width,height, viewMatrix, projectionMatrix, faceTransform` (alle als storage-Listen).
- `BakePose` (texture_baker): `image, vertices(List<Vector3>, face-local),
  projection(PoseProjection)`.
- `PoseProjection` (`domain/v3/texture_projection.dart`):
  `pixel = projection · view · faceTransform · [v,1]` → NDC → Pixel (top-left).
- **Wichtig (Registrierung):** Jede Pose nutzt ihre EIGENEN `vertices` +
  Matrizen. Topologie ist konstant → dasselbe `(triangle, barycentric)` = dasselbe
  Landmark über alle Posen. `TextureBaker._sampleFace` interpoliert die
  pose-eigenen Vertices an `bc`, projiziert, bilinear-sampled. D.h. Registrierung
  stimmt bereits pro Pose; **die Normalen ändern nur die GEWICHTUNG**, welches
  Foto man pro Fläche vertraut.

### Aktuelle Auswahl (zu ersetzen)
In `texture_baker.dart`:
- `_pickSide(a,b,c)` — Links/Rechts per `FaceRegions` (X-Split,
  `domain/constants/face_regions.g.dart`, generiert von `tool/generate_face_regions.dart`).
- `sideWeight[i]` — Ramp frontal↔Seite.
- `downWeight[i]` (neu) — Chin-up-Anteil via horizontaler Achse
  (`_computeDownWeights` in session_baker, `FaceHorizontalAxis` in
  `domain/constants/face_vertex_indices.dart`).
- Blend: `colour = lerp(frontal, side, wSide); colour = lerp(colour, up, wDown)`.

### Vorhandene Toggles (⚙-Sheet, `presentation/debug/debug_settings.dart`)
- `hiResPhoto` (Texturquelle ARKit-Video ↔ AVCapture) — **behalten**.
- `fillHoles` — behalten.
- `chinUpLowerFace` + Tunables `_downStartFraction/_downFullFraction` — regionsbasiert,
  wird vom Normalen-Weg **abgelöst** (als Fallback behalten oder entfernen).
- `flipSides` (nur Code/CLI) — mit Normalen vermutlich überflüssig.

---

## 3. Plan: view-dependent Gewichtung

### Kern-Mathematik (pro Vertex, pro Pose p)
Alles in **Welt-Koordinaten** rechnen, konsistent pro Pose:
- Face-local Vertex `v` (aus `BakePose.vertices`).
- `worldP = faceTransform_p · v`
- `camPos_p = inverse(viewMatrix_p) · (0,0,0,1)` → xyz (Kamera-Ursprung in Welt).
- `viewDir = normalize(camPos_p − worldP)`
- `nLocal` aus `domain/v3/vertex_normals.dart:computeVertexNormals(faceLocalVerts, triangles)`
  (Topologie konstant → **einmal** aus frontal-Vertices berechnen).
- `nWorld_p = normalize(rot3x3(faceTransform_p) · nLocal)`  (faceTransform ist rigide → Rotationsteil genügt)
- `facing_p = dot(nWorld_p, viewDir)`
- `weight_p = pow(clamp(facing_p, 0, 1), k)`  (k≈2..4 schärft die Auswahl)

Dann über die verfügbaren Posen **normalisieren** und Farben blenden
(oder Top-1/Top-2 picken). Sample ungültig (projectPixel null / außerhalb Bild)
→ `weight_p = 0`.

### Guards (wichtig, sonst schlechter als vorher)
1. **Symmetrieachs-Guard:** Gewicht einer Seiten-Pose jenseits der Mittelachse
   (`FaceSymmetryAxis`, `domain/constants/face_vertex_indices.dart`) hart auf 0 →
   kein Übersprechen über die Nase. (Der Nutzer will diese Logik ausdrücklich behalten.)
2. **Mindest-Winkel:** `facing_p < ~0.2` verwerfen (streifende, verzerrte Samples).
3. **Occlusion:** `n·v` löst Verdeckung NICHT (z.B. Nase verdeckt Philtrum im
   Chin-up-Foto). Optional später echter Tiefen-/Sichtbarkeitstest; vorerst hilft
   Mindest-Winkel + dass abwärts gerichtete Flächen die Chin-up-Pose bevorzugen.
4. **Farb-/Belichtungs-Konsistenz:** Jedes AVCapture-Foto hat eigene AE/AWB →
   Nähte beim Blenden. Weiches Blenden (normalisierte Gewichte) mildert; besser
   jede Pose farblich auf frontal normieren. **Prüfen:** Git-Historie hat
   `commit 98b1e53 "Add ml-wb white-balance color normalization"` — evtl. wiederverwendbar
   (`git show 98b1e53`). Das ist der Haupt-Qualitätshebel, sobald mehr geblendet wird.

### Wo implementieren
- `TextureBaker.bake` von (frontal,left,right,up + Tabellen) auf eine **Liste von
  BakePoses** + pro-Pose-Weltnormalen umstellen; `_pickSide`/`sideWeight`/`downWeight`
  durch die `n·v`-Gewichtung ersetzen. Im Isolate (`_runBake`) lassen (Perf).
- `BakePose` muss `viewMatrix` + `faceTransform` verfügbar machen (aktuell nur in
  `PoseProjection` gekapselt). `_PoseInput`/`StillCapture` tragen sie bereits →
  einfach durchreichen (z.B. Felder an `BakePose` ergänzen).
- Normalen: `computeVertexNormals` einmal aus frontal-Vertices; für jede Pose mit
  deren `faceTransform`-Rotation nach Welt drehen (oder pro Pose neu — identisch,
  da rigide).
- Cap-Vertices (fillHoles, ab `capBase`): `assignCapNormals` existiert für OBJ;
  fürs Blenden Cap-Centroiden z.B. wie frontal/center behandeln.

---

## 4. Empfohlener inkrementeller Weg

- **A:** Per-Vertex-`n·v`-Gewichtung + normalisierter Blend über alle Posen in
  `TextureBaker` — hinter neuem Toggle „View-dependent blend" (A/B gegen aktuell).
- **B:** Symmetrieachs-Guard + Mindest-Winkel.
- **C:** Farbangleich der Posen an frontal (ml-wb prüfen).
- **D (optional):** Occlusion/Tiefentest, falls Artefakte bleiben.

Alternativen (bewertet): (a) Per-Triangle Best-View statt Blend (weniger Nähte,
billig, guter Zwischenschritt); (b) volles MVS-Texturing mit Graph-Cut-Seams +
Gradient-Domain-Blending (beste Qualität, hoher Aufwand, aktuell overkill).

---

## 5. Gotchas / Konventionen
- Matrizen column-major, `Matrix4.fromList`, `vector_math_64`. `viewMatrix` =
  world→camera. Kamera-Weltposition: `viewMatrix.clone()..invert()` dann
  `transform3(Vector3.zero())` bzw. `* Vector4(0,0,0,1)`.
- `faceTransform` = face-local→world, rigide (Rotation+Translation, keine Skalierung)
  → für Normalen Rotationsteil nehmen.
- Front-Kamera-Spiegelung ist nativ bereits ARKit-konform behandelt; die
  bestehende Bake funktioniert mit diesen Stills → Projektion/Facing konsistent.
- Die 4. Pose („Chin up") **behalten** — sie ist eine zusätzliche Ansicht, die der
  Normalen-Ansatz automatisch für Kinn/Unterkiefer nutzt.
- Tests: `test/application/capture_bloc_test.dart` nutzt `captureSequence`
  generisch (ok). Bake hat keinen Unit-Test; eine reine `n·v`-Gewichtungs-Funktion
  ließe sich gut testen.

## 6. Schlüssel-Dateien (Kurzreferenz)
- Posen/Achsen: `domain/entities/face_pose.dart`, `domain/constants/face_vertex_indices.dart`
- Regionen (evtl. retire): `domain/constants/face_regions.g.dart` (+ `tool/generate_face_regions.dart`)
- Bake: `data/bake/session_baker.dart`, `data/bake/texture_baker.dart`
- Projektion/Normalen: `domain/v3/texture_projection.dart`, `domain/v3/vertex_normals.dart`, `domain/v3/hole_filler.dart`
- Still/Repo: `domain/entities/still_capture.dart`, `data/file_snapshot_repository.dart`
- Nativer Capture: `ios/Runner/AppDelegate.swift`
- Settings: `presentation/debug/debug_settings.dart`, `presentation/capture_page.dart` (`_openDebugSheet`, `_bakeTexture`)
- Offline-Bake (schnelles Iterieren ohne Gerät): `tool/bake_texture.dart` gegen einen gespeicherten Session-Ordner
- Aktuelle Optionsübersicht: `OPTIONS.md`
