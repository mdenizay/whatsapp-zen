# WhatsApp Zen for Linux (experimental)

A light, native WhatsApp client for Linux, built with GTK 4 and libadwaita on
the same Rust core as the macOS app. Unofficial; not affiliated with WhatsApp.

## Install

- Debian / Ubuntu 24.04 or later: `sudo apt install ./whatsapp-zen_*_amd64.deb`
- Others: unpack the tarball and run `./whatsapp-zen`. It needs GTK 4.12+ and
  libadwaita 1.5+ (Fedora 40+, Arch, openSUSE Tumbleweed, Debian 13).
  To add it to your app menu, copy the `.desktop` file to
  `~/.local/share/applications/` and the icon to
  `~/.local/share/icons/hicolor/256x256/apps/`, and put `whatsapp-zen` on your PATH.

## First start

Open WhatsApp on your phone → Settings → Linked Devices → Link a Device, and
scan the code the app shows. Messages are kept in `~/.local/share/whatsapp-zen`.

## What works

Chat list with search, reading and sending messages (↩ sends, ⇧↩ new line),
replies, reactions, photos, files, downloads, deleting, notifications.
Not yet: voice and video calls, voice recording, chat lists, themes, several
accounts. Please report problems at https://github.com/mdenizay/whatsapp-zen/issues
