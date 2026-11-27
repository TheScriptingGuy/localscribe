#!/bin/sh
# Turns the source tree into the F-Droid variant (run from the repo root,
# before `flutter pub get`):
#  - drops sherpa_onnx (prebuilt onnxruntime .so files) and swaps the
#    on-device speaker recognition for a stub; everything else is identical.
# Used by the F-Droid build recipe and by the fdroid-variant CI job.
set -eu
cd "$(dirname "$0")/../.."

cp tool/fdroid/local_diarizer_stub.dart lib/services/diarization/local_diarizer.dart
# Remove the dependency line and its comment block from pubspec.yaml.
sed -i '/^  sherpa_onnx:/d' pubspec.yaml
if grep -rq "package:sherpa_onnx" lib; then
  echo "sherpa_onnx is still imported:" >&2
  grep -rn "package:sherpa_onnx" lib >&2
  exit 1
fi
echo "F-Droid variant prepared."
