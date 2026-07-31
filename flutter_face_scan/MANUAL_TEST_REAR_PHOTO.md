# Manual test — Clinician Rear Photo

Stand: nach Idle-Rear-Preview + Settings-Abbruch-Fixes.

## Erledigt (von dir bestätigt)

| Check | Ergebnis |
|---|---|
| User / Clinician Front unverändert | Passt |
| Clinician · Rear · Photo: Rückkamera sichtbar | Ja |
| Idle zeigt Rear wenn Clinician·Rear gewählt | Passt |
| Settings öffnen während Scan → Abbruch | Passt |
| Settings ändern nach Scan → wieder Start | Passt |
| Threading-Error EventChannel | Weg |

## Später nachholen — Photo-Pfad (allein / mit zweiter Person)

> Video-Pfad ist zusätzlich implementiert; Photo-Checks unten bleiben offen.

### Mit Patient / zweitem Gesicht

1. **Vision-Tracking:** Gesicht wird erkannt, Outline füllt sich, Guidance kommt.
2. **Links/Rechts nicht vertauscht:**
   - Hinweis `Right side of the face` → iPad so bewegen, dass die **rechte** Wange des Patienten die Kamera sieht → Capture.
   - Hinweis `Left side of the face` → linke Wange → Capture.
   - Wenn vertauscht: kurz Bescheid sagen (Yaw-Sign flip).
3. **Chin-up:** Hinweis `Under the chin` → iPad etwas tiefer, Blick von unten → Capture.
4. **Hold:** ~2–3 s grün / „hold still“ → Pose wird übernommen.

### Session / Dateien

5. **4 JPEGs gespeichert:** nach komplettem Scan Ordner  
   `Documents/face_scans/session_*/`  
   → `frontal.jpg`, `left40.jpg`, `right40.jpg`, `up.jpg` (oder gleichwertige Namen) vorhanden und sinnvoll belichtet.
6. **Manifest:** `captureActor=practitioner`, `clinicianCamera=rear`, `rearCaptureKind=still`.
7. **Kein sinnvoller Bake** auf diesen Fotos (erwartet — kein TrueDepth-Mesh). Bake ggf. fehlschlagen / unsinnig → OK.

### Nach dem Scan

8. **Idle-Preview nach Scan:** bei weiterhin Clinician·Rear → **Rückkamera** bleibt im Idle (nicht Front).
9. **User/Front gewählt:** Idle zeigt wieder Front-Preview.
10. **Settings während Scan öffnen:** laufender Scan bricht ab.
11. **Settings nach „Scan again“ ändern:** Button wird wieder **Start** (nicht Scan again).
12. **Hot path:** Cancel mit X → Idle + passende Preview (Front oder Rear je Settings).

## Von dir gesagt / nicht testbar gewesen

- Allein → Tracking Links/Rechts/Chin-up und 4-Foto-Persistenz nicht geprüft.
- Nach-Scan Front/Rear-Preview-Wechsel und voller Save-Pfad offen.

## Neu — Prior mesh

Settings: Clinician · Prior mesh · Prior mesh scan wählen · Front/Rear.

| Check | Status |
|---|---|
| Liste zeigt nur Scans mit Mesh (`frontal.ply` + Bake-JPGs) | offen |
| Start ohne Auswahl → Snackbar | offen |
| Start: **kein** Mesh-Pass, direkt Photos | offen |
| Session: Mesh/Bake-JPGs aus Ref + neue `*_rear.jpg` | offen |
| Manifest: `meshRefSessionId` gesetzt | offen |
| Bake nutzt Prior-Mesh-Epoche (Front-Stills der Ref) | offen |

## Neu — Mesh now → Rear (sequentiell)

Settings: Clinician · Mesh now · Rear · Photo (oder Video) · Mesh motion Head/iPad.

| Check | Status |
|---|---|
| Idle: Rear-Preview + Text „Head mesh · then rear…“ / Orbit-Variante | offen |
| Start: wechselt auf **Front** für Mesh-Pass (4 Winkel) | offen |
| Mesh motion Head → Self-Scan-Hints; iPad → Orbit-Hints | offen |
| Nach Mesh: Banner „Mesh done — rear photos“, Preview → Rear | offen |
| Photo-Pass: 4 Rear-Winkel (Orbit-Guidance) | offen |
| Session: `frontal.jpg`… (Front/Bake) **plus** `frontal_rear.jpg`… | offen |
| Manifest: `schemaVersion=4`, `meshPass` + `photoPass` | offen |
| Bake mit Front-Stills möglich („bake ready“) | offen |

## Neu — Rear Video (Sharpness-Harvest)

| Check | Status |
|---|---|
| Settings · Rear · Video → Idle-Text `Rear video · sharpest frames` | offen |
| Start: Preview bleibt Rear (ggf. 4K) — nur bei Prior mesh / ohne Mesh now | offen |
| Während Hold: unscharfe Schwenks werden verworfen, schärfstes Frame gewinnt | offen |
| 4 JPEGs aus Video-Frames gespeichert | offen |
| Photo-Mode weiterhin volle AVCapture-Stills | offen |

## Kurz rückmelden

- Tracking ok? Links/Rechts korrekt?
- 4 JPEGs im Session-Ordner?
- Idle-Preview Front/Rear wie erwartet?
- Settings-Abbruch + Start statt Scan again ok?
- Video vs Photo Unterschied spürbar?
