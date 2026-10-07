# WhatsApp Zen for Windows (experimental)

A light, native WhatsApp client for Windows 10 and 11, built with WinUI 3 on
the same Rust core as the macOS app. Unofficial; not affiliated with WhatsApp.

## Install

Unzip the folder anywhere (for example `%LOCALAPPDATA%\Programs\WhatsApp Zen`)
and run `WhatsAppZen.exe`. Nothing else needs installing. The app is not
signed yet, so Windows SmartScreen may warn on first start: choose
"More info" → "Run anyway".

## First start

Open WhatsApp on your phone → Settings → Linked Devices → Link a Device, and
scan the code the app shows. Messages are kept in `%LOCALAPPDATA%\WhatsAppZen`.

## What works

Chat list with search, reading and sending messages (Enter sends, Shift+Enter
new line), replies, reactions, photos, files, downloads, deleting,
notifications. Not yet: voice and video calls, voice recording, chat lists,
themes, several accounts. Please report problems at
https://github.com/mdenizay/whatsapp-zen/issues
