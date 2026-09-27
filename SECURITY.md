# Security

Mac Connect moves SMS, call history, files, notifications and your phone's screen between two
devices, so security reports matter here.

## Reporting a problem

Please open a [security advisory](https://github.com/hussaintrawadi/mac-connect/security/advisories/new)
rather than a public issue, and allow some time for a fix before sharing details.

## The current threat model

- **Local network only.** There is no server, account or cloud relay. The apps only talk to
  each other on the same network.
- **Pairing is explicit.** A phone can only connect after scanning the QR code shown on the
  Mac. Device IDs and key fingerprints are exchanged at that point.
- **No transport encryption yet.** The connection is plain TCP. Anyone on the same network
  who can capture traffic could read it. Use Mac Connect on networks you trust, not on
  public Wi-Fi. TLS is the most wanted contribution.
- **Powerful Android permissions.** The Accessibility service injects touches and text, and
  the app reads SMS and the call log. Install builds only from this repository or ones you
  compiled yourself.

## Keeping your build safe

- Your Android signing keystore and `AndroidApp/keystore.properties` are git-ignored. Keep
  them that way, and back the keystore up: updates must be signed with the same key.
