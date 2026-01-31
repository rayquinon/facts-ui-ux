# facts_ui_ux

Flutter app for attendance + reporting.

## DOCX Attendance Export

The attendance report is exported as a `.docx` using a Word template with Content Controls (SDTs).

### What to verify in Word

- Dates: should be formatted as `M/D/YY`.
- Date header text: smaller font (template normalization enforces this).
- Date/mark cells: left-aligned text and vertically centered in the cell.
- Student rows: row height should be `Exactly 0.6 cm` (not “At least”).

### Debug tool (local only)

There is a local debug generator that produces a small DOCX with sentinel values:

- Run: `dart run tool/debug_docx_fill.dart --force`
- Or: set `DOCX_DEBUG=1` and run without `--force`

It writes `build/debug_out.docx`.

## Android Release APK

### Signing

This repo supports a real release keystore via `android/key.properties`.

- Copy [android/key.properties.example](android/key.properties.example) to `android/key.properties` and fill it in.
- Keep the keystore file out of git (recommended location: `keystore/` in your local machine).

If `android/key.properties` is not present, Android release builds fall back to debug signing (OK for internal testing, not for store releases).

### Build + Publish “Latest” APK to Hosting

- Run: `powershell -ExecutionPolicy Bypass -File tools/release_apk.ps1`
- Outputs:
	- `public/downloads/app-latest.apk` (stable link)
	- `public/downloads/app-latest-<version>.apk` (version-stamped)
	- plus per-ABI variants (`arm64`, `armeabi-v7a`, `x86_64`)

This script also rebuilds web and runs `firebase deploy --only hosting`.
