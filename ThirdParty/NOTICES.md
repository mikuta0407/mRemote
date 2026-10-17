# Third-party notices

The Phase 0 native binary contains code from the following projects:

- FreeRDP and WinPR, Copyright their respective contributors, licensed under Apache-2.0.
- OpenSSL, Copyright OpenSSL contributors, licensed under Apache-2.0.
- TPCircularBuffer, Copyright (C) 2012-2013 A Tasty Pixel, licensed under the Zlib license.
- The WinPR internal MD4/MD5 implementations by Alexander Peslyak (Solar Designer), dedicated to
  the public domain with permissive fallback terms if that dedication is ineffective.
- WinPR's HashTable implementation, based on a public-domain implementation by Keith Pomakis;
  WinPR's changes remain Apache-2.0.
- macrdpx (Mac RDP eXtensions, `external/macrdpx`), Copyright (c) 2026 mikuta0407, licensed under
  the MIT license. Compiled into the bridge.
- libssh2, Copyright the libssh2 project and its contributors, licensed under the BSD-3-Clause
  license. Built from the commit in `config/dependencies/libssh2.lock` into `mRemoteSSH.xcframework`.
- SwiftTerm, Copyright (c) Miguel de Icaza and contributors, licensed under the MIT license. Linked
  as a Swift package, version 1.20.0.
- Unicode CLDR `windowsZones.xml` data represented by WinPR's generated `WindowsZones.c`,
  Copyright Unicode, Inc., licensed under Unicode-DFS-2016.

The distributed license/notice texts are:

- [`licenses/Apache-2.0.txt`](licenses/Apache-2.0.txt)
- [`licenses/TPCircularBuffer-Zlib.txt`](licenses/TPCircularBuffer-Zlib.txt)
- [`licenses/Solar-Designer-MD4-MD5.txt`](licenses/Solar-Designer-MD4-MD5.txt)
- [`licenses/Keith-Pomakis-HashTable-public-domain.txt`](licenses/Keith-Pomakis-HashTable-public-domain.txt)
- [`licenses/Unicode-DFS-2016.txt`](licenses/Unicode-DFS-2016.txt)
- [`licenses/macrdpx-MIT.txt`](licenses/macrdpx-MIT.txt)
- [`licenses/libssh2-BSD-3-Clause.txt`](licenses/libssh2-BSD-3-Clause.txt)
- [`licenses/SwiftTerm-MIT.txt`](licenses/SwiftTerm-MIT.txt)

Exact upstream project licenses and the separately licensed bundled source files are verified by
the SHA-256 values in `config/dependencies/freerdp.lock` before a binary is built.

No project-level upstream `NOTICE` file is present at the locked FreeRDP commit or in the locked
OpenSSL release archive. The file-level notices enumerated above are nevertheless part of this
distribution. OpenSSL's `ACKNOWLEDGEMENTS.md` is informational rather than a redistribution notice;
it should be reviewed again when OpenSSL is updated.
