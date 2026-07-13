# Reference captures

Put your neutral **frontal** ARKit face PLY here as:

    tool/reference/frontal.ply

Then generate the region table (from the project root):

    dart run tool/generate_face_regions.dart tool/reference/frontal.ply

This writes `lib/features/face_capture/domain/constants/face_regions.g.dart`.

Tune the split with flags, e.g. a wider central region:

    dart run tool/generate_face_regions.dart tool/reference/frontal.ply --center=0.40 --blend=0.10

Commit both the reference `frontal.ply` and the generated `face_regions.g.dart`
so the regions are reproducible.

## Merging a session

After capturing a full 3-pose session (frontal + left40 + right40) with the
updated app, pull the three `.ply` files and fuse them:

    dart run tool/merge_regions.dart frontal.ply left40.ply right40.ply

Writes `merged.ply` next to the input — the front from the frontal scan, the
cheeks from the side scans, blended smoothly. If the region sides look mirrored,
add `--flip`.

Note: the merge reads `FaceRegions.sideWeight`, so regenerate `face_regions.g.dart`
with the current generator first (the older output has no weights).
