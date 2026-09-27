# Release signing

The keystore is **never committed** — each maintainer/builder uses their own.
Without one, `./gradlew assembleRelease` simply signs with the debug key, which is
fine for personal use.

## Create a keystore

```bash
keytool -genkeypair -v \
  -keystore AndroidApp/keystore/release.jks \
  -alias myalias -keyalg RSA -keysize 2048 -validity 10000
```

## Tell Gradle about it

Create `AndroidApp/keystore.properties` (this file is gitignored):

```properties
storeFile=keystore/release.jks
storePassword=YOUR_STORE_PASSWORD
keyAlias=myalias
keyPassword=YOUR_KEY_PASSWORD
```

Or use environment variables instead: `MC_KEYSTORE_FILE`, `MC_KEYSTORE_PASSWORD`,
`MC_KEY_ALIAS`, `MC_KEY_PASSWORD`.

> Keep the keystore safe and backed up: APK updates must be signed with the same key,
> or Android will refuse to install them over the old version.
