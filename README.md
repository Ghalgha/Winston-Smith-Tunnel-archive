# Winston Smith Tunnel (WST)

Winston Smith Tunnel is an Android client and Rust-based tunnelling project derived from the CSQTT codebase.

## Project status

This repository contains the imported source tree. The public-facing Android application ID is `com.wstunnel.client`. The Kotlin namespace remains `com.csqtt.client` for source compatibility; this is an internal package namespace, not the installed application identity.

## Build

- Android Studio with Android SDK 37
- JDK 17
- Rust toolchain required for native components
- Use the Gradle wrapper: `./gradlew :app:assembleDebug`

Release builds require a separately configured signing keystore. Keep signing credentials and `local.properties` out of version control.

## Licensing and attribution

This project retains the upstream **PolyForm Noncommercial License 1.0.0** and all required notices. The original CSQTT project and its author remain credited in the license and legal notices. Commercial use requires separate written permission from the licensor. See [LICENSE](LICENSE) and the in-app third-party/license notices.

WST is a derivative work; rebranding does not change the upstream license terms.
