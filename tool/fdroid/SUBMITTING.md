# Getting LocalScribe into F-Droid

Two channels:

1. **Self-hosted repository** (works now): pushing a `v*` tag builds the APK
   and publishes it to https://thescriptingguy.github.io/localscribe/
   (`publish-fdroid-repo` job in `.github/workflows/build.yml`). The repo
   signing key is in the `FDROID_KEYSTORE_*` secrets; keep the offline backup
   safe, since losing it means users must re-add the repository.

2. **Official F-Droid** (built and signed by F-Droid):
   - Fork https://gitlab.com/fdroid/fdroiddata, add
     `tool/fdroid/fdroiddata/ai.localscribe.localscribe.yml` as
     `metadata/ai.localscribe.localscribe.yml`, run `fdroid lint` and
     `fdroid build -v -l ai.localscribe.localscribe` (fdroidserver docker
     image) to check, and open a merge request using the "App inclusion"
     template.
   - The recipe builds the F-Droid variant (`tool/fdroid/prepare.sh`), which
     leaves out on-device speaker recognition: sherpa-onnx only ships prebuilt
     onnxruntime libraries. CI's `fdroid-variant` job keeps that variant
     compiling.
   - Store texts and screenshots are read from `fastlane/metadata/android`.
   - F-Droid signs its builds with its own key, so its APK cannot update one
     installed from GitHub or the self-hosted repository (and vice versa).
   - Expect review questions about the Plaud integration; the NonFreeNet
     anti-feature covers the optional Plaud sign-in.
   - If F-Droid's build crashes in `lintVital*` tasks (seen on GitHub's
     runners), add the Gradle init script from the "Disable lintVital" step of
     `.github/workflows/build.yml` to the recipe's prebuild.
