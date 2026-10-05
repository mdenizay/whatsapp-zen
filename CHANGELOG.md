# Changelog

The section for the running version is shown in the app after an update.

## 0.7.10

- Shift-Return (or Option-Return) starts a new line in a message; Return alone still sends
- Esc drops the reply or the edit being written

## 0.7.9

- Delete for Me: any message can be removed from your own devices; Delete for Everyone stays for your messages of the last two and a half days, both from "Delete…" in the message menu
- Messages deleted for you on the phone disappear here too
- Restarting to update is reliable: the new version is put in place only after the app has quit, and an open Settings window no longer keeps it from quitting

## 0.7.8

- Older messages are fetched from your phone: a chat that had only a few messages on this Mac fills in when opened, and "Get older messages from your phone" at the top of a conversation brings more
- A chat with no messages on this Mac says so instead of opening blank
- Newly linked accounts receive a year of history

## 0.7.7

- Opening a chat puts the cursor in the message field again, so you can type straight away
- Loading older messages keeps your place instead of jumping

## 0.7.6

- Touch ID now comes up when asked for from the menu bar panel (app lock or a locked chat)

## 0.7.5

- Pinned and muted chats no longer lose their state after a while (a later history sync was clearing it)

## 0.7.4

- A softer chat info panel: smaller header, round action buttons, a lighter tab bar
- Shared photos without an embedded thumbnail now show in the media grid

## 0.7.3

- Settings reorganised: shorter panes, a new Chats pane for message and chat-list options, Appearance reduced to the theme and background
- Lower memory use: unchanged chat and message data is no longer decoded again, full-size pictures are not kept after the viewer closes, and freed memory is handed back to the system

## 0.7.2

- The theme is shown from the start, not only once a chat is open

## 0.7.1

- Theme picker: the second colour is the opposite of the first, and the two dots move together across the field
- A pale theme colour no longer washes out buttons and bubbles

## 0.7.0

- A theme picker in the manner of Arc and Zen: drag a dot across a colour field, add a second for a gradient, choose light or dark, set how strongly the colours tint the window
- A first-run setup that walks through colours, message style, notifications and privacy (Settings → General → Run Setup Again…)

## 0.6.3

- Each account can have a look of its own: theme, accent colour, chat background, font and bubble style (Settings → Appearance → "A separate look for…"). Switching accounts switches the look.

## 0.6.2

- Locations are shown as a small map with a pin; click to open in Maps
- A more compact + panel; stickers, emoji, polls and contacts now open inside it, next to the + button
- A built-in emoji picker

## 0.6.1

- The + button opens a panel of coloured tiles instead of a plain menu
- Click a sticker in a chat to add it to your favourites

## 0.6.0

More ways to make it yours, in Settings → Appearance:

- Light, dark or system theme
- Any accent colour, not only the presets
- Chat background: plain, tinted, gradient, or your own picture
- Message font (standard, rounded, serif, monospaced) and bubble corner roundness
- 12-hour clock
- Choose your own quick reactions
- Chat list: one or two preview lines, round or square profile photos

Stickers:

- Make a sticker out of any picture (＋ → Sticker… → Create from Image…)
- Keep favourites: right-click a sticker → Add to Favorites; they come first in the picker

## 0.5.3

- Typed emoticons such as :) ;) :D <3 turn into emoji (can be switched off in Settings → General)
- The chat list keeps its width when you switch chats
- With the chat list hidden, a button next to it lists your recent chats

## 0.5.2

- A chat opens at its newest message and stays there as messages arrive
- A line marks where the unread messages begin
- The chat list no longer changes width by itself
- Less redrawing: rows that did not change are skipped, the main window stops updating while closed, profile photos are looked up once

## 0.5.1

- Split view lays out properly and widens a narrow window
- Hiding or showing the chat list no longer jitters
- Click and hold the chat-list button for a menu of recent chats
- Groups whose history held nothing displayable were missing from the chat list; they are listed now
- Event messages in groups are shown

## 0.5.0

- Photos go through a send screen first: crop, rotate, draw, add arrows and boxes, write a caption; several photos at once
- Photos and videos open in a viewer inside the app: zoom, step through the chat's media, copy, save
- Split view: right-click a chat → Open Beside Current Chat to see two conversations in the main window
- Open any chat in a window of its own (right-click a chat → Open in New Window) to keep several conversations side by side
- Settings → Storage shows the downloaded media; open or remove items one by one
- Lighter on the system: less work when receipts arrive in bursts, less memory held while idle

## 0.4.2

- A redesigned chat info panel: bigger header, one-tap actions, and shared photos, documents and links that open on click
- Click the name or photo at the top of a chat to open its info

## 0.4.1

- Settings → Privacy shows whether FileVault is encrypting what the app stores
- A nicer icon picker for accounts, with more icons

## 0.4.0

**Finding things**
- Search now looks through the messages of every chat, not only chat names
- **⌘K** jumps to any chat; **⌘1–9** open the first chats, **⌥⌘↑ / ⌥⌘↓** step through them
- A chat's info panel (**⌘I**) lists its photos, documents and links

**Writing**
- Mention people in groups by typing **@**
- Send several photos or files at once
- Crop and rotate a photo before sending it
- Links you send get a preview card, and received ones show theirs
- Polls: create them and vote
- Send a contact card, your location, or a sticker you have received
- Unsent text is kept as a draft per chat
- **↑** in an empty message field edits your last message; **Esc** cancels a reply

**Chats**
- Mute a chat for 8 hours, a week or always
- Disappearing messages: see and change the timer
- Status updates from your contacts (Go → Status)
- Block a contact, export a chat as text
- View-once messages are announced (they can only be opened on the phone)
- Text inside a message can be selected again; the react and reply buttons sit next to the bubble

**Privacy**
- Lock the whole app, or single chats, with Touch ID
- Pause notifications for a while (Do Not Disturb)

**Settings**
- Appearance: text size, accent colour, compact chat list
- Optional unread count in the menu bar
- Storage: turn off automatic photo downloads, clear downloaded media
- Release notes like these after each update

## 0.3.6

- The account switcher and Settings moved to the top of the sidebar
- Accounts can be given a name and an icon

## 0.3.5

- The "delivered" tick is readable on outgoing bubbles

## 0.3.4

- The app updates itself
