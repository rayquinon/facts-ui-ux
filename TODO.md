# In-App Update Fix TODO

- [x] Step 1: Update pubspec.yaml version to 1.1.13+4126
- [x] Step 2: Run `flutter pub get`
- [x] Step 3: Build and release new APK using `tools/release_apk.ps1`
- [x] Step 4: Update public/downloads/version.json (latestBuildNumber: 4126, latestVersionName: '1.1.13', update APK URLs)
- [x] Step 5: Deploy web (`tools/deploy_web.ps1` or `firebase deploy`)

- [ ] Step 6: Test with old APK install: launch app → confirm update dialog shows → downloads new APK.

Progress: Ready for edits.
