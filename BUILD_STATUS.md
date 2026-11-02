# Build status

- Android CI builds a debug APK for automated compilation verification only; it is not published as a user release.
- Signed Android releases are created only by the manual workflow `.github/workflows/android-release.yml`.
- Release signing requires GitHub Actions secrets: `KEYSTORE_BASE64`, `KEYSTORE_PASSWORD`, `KEY_ALIAS`, and `KEY_PASSWORD`.
- The embedded server web panel is implemented in `rust-server/web_panel.rs`; its PWA branding and cache version are maintained there.
