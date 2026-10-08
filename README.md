# WhatsApp Zen

A small, native macOS client for WhatsApp: a SwiftUI/AppKit interface on top of
a Rust core built on the [whatsapp-rust](https://github.com/oxidezap/whatsapp-rust)
protocol library. It links
to your account as a companion device (like WhatsApp Web) and uses a fraction
of the memory of the official app.

![The main window: chat list and a conversation](docs/main.png)

| Menu bar: recent chats | Menu bar: reply in place | Settings |
| --- | --- | --- |
| ![Recent chats in the menu bar panel](docs/menu-list.png) | ![A conversation in the menu bar panel](docs/menu-chat.png) | ![The Settings window](docs/settings.png) |

> **Unofficial.** This project is not affiliated with, endorsed by, or
> connected to WhatsApp or Meta. Third-party clients are against WhatsApp's
> Terms of Service and using one may get your account restricted or banned.
> Use it at your own risk. "WhatsApp" and its logo are trademarks of
> WhatsApp LLC.

## Features

- Chats and groups: text, photos, videos, documents, voice messages (record
  and play), stickers, polls, contact cards, locations, replies, reactions,
  mentions, link previews, edit and delete-for-everyone
- Read receipts, typing indicator, online / last seen, profile photos
- Paste or drag-and-drop photos and files, several at a time
- Search across all chats; jump to a chat with ⌘K
- Pin, archive and mute chats; star, pin and forward messages; drafts
- Disappearing messages, status updates, blocking, chat export
- Group management: members, admins, rename, invite link, leave
- A menu bar panel with your recent chats that you can read and answer from
  without opening the app
- Notifications with inline reply, and a Do Not Disturb pause
- App lock and per-chat lock with Touch ID
- Multiple accounts, each with a name and an icon
- Appearance settings: text size, accent colour, compact list
- Updates itself from GitHub releases (each download is checked against the
  developer signature before it is installed)
- English, Turkish, Russian, French, German, Spanish, Portuguese and Italian;
  follows the system (or per-app) language

Voice and video calls are new and lightly tested (one-to-one only, no echo
cancellation: use headphones). Not supported: group calls, posting status
updates, view-once media, communities and channels. Messages are stored
unencrypted on disk; rely on FileVault for encryption at rest.

## Install

Requires macOS 26 or later on Apple silicon.

```bash
brew install --cask mdenizay/tap/whatsapp-zen
```

The app is signed and notarized, so it opens like any other.

Then open the app and scan the QR code from WhatsApp on your phone
(Settings → Linked Devices → Link a Device).

## Build from source

You need Xcode 26 or later (or its Command Line Tools) and Rust.

```bash
brew install rustup && rustup toolchain install stable
./build.sh
open "dist/WhatsApp Zen.app"
```

## How it is put together

| Part | What it is |
| --- | --- |
| `zen/core/` | Rust. Wraps whatsapp-rust, keeps chats and messages in SQLite, and is built as a C static library. Its surface is `WAStart`, `WACall` (JSON command in, JSON reply out), an event callback, and two functions for the video of a call. It has no macOS in it: the same core is meant to sit under native apps for Windows and Linux. |
| `core/` | Go. The core the app used up to 0.9, on whatsmeow, with the same C surface (without calls). `CORE=go ./build.sh` still builds with it. |
| `app/` | Swift. The SwiftUI/AppKit interface, linked against the core. |
| `tools/` | The script that draws the app icon. |

Data lives in `~/Library/Application Support/WhatsAppZen/`, one folder per
account. Nothing is sent anywhere except to WhatsApp's own servers.

Running the app with `WA_DEMO=1` shows the interface on made-up data without
touching any account. The screenshots above come from that mode: with
`WA_SNAPSHOT=<folder>` as well, the app writes pictures of its windows there
and quits, and `tools/frame-screenshot.swift` puts each on a background.

## Credits and license

- [whatsapp-rust](https://github.com/oxidezap/whatsapp-rust) by João Lucas de Oliveira Lopes and contributors (MIT)
- [whatsmeow](https://github.com/tulir/whatsmeow) by Tulir Asokan (MPL-2.0), which the first versions were built on
- WhatsApp glyph from [Simple Icons](https://simpleicons.org) (CC0)

This project's own code is released under the MIT License; see `LICENSE`.
