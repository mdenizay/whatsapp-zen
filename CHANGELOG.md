# Changelog

The section for the running version is shown in the app after an update.

## 1.0.1

- After updating to 1.0, contact names are taken over from the old engine's data, so chats show names straight away instead of phone numbers

## 1.0.0

- A new engine. The part of the app that talks to WhatsApp has been rewritten in Rust. Everything looks and works as before, and it is what makes the calls below, and versions for Windows and Linux, possible
- Link once more: the new engine cannot take over the old link, so the app shows the pairing code after this update. Your chats and messages stay. The old "WhatsApp Zen" entry under Linked Devices on your phone can be removed
- Voice calls (new, still being proven): a phone button in one-to-one chats, and incoming calls ring in a small window with Accept and Decline. There is no echo cancelling yet, so headphones are recommended
- Video calls (new, still being proven): a video button next to it; the camera can be turned on and off during a call
- A group's name follows changes as they happen

## 0.9.4

- The log now records the read-receipt setting WhatsApp reports for the account, to make "why do I see blue ticks" answerable

## 0.9.3

- The menu bar icon is drawn at its proper size again (it had shrunk into a corner in 0.9.1)
- Select several messages: "Select Messages" in a message's menu, click the ones you want, then copy them together (each with who and when) or delete them for yourself
- Clicking the quoted message in a reply goes to the original, loading the conversation back to it if needed, and marks it clearly
- A chat with a message left half written moves to the top of the list, under the pinned ones
- Large files show how far the download is, and are saved straight to disk instead of being held in memory
- With your read receipts off, one-to-one chats no longer show others' blue ticks, as on the phone (groups still do); a voice message being played no longer counts as read

## 0.9.2

- Notifications: choose what a banner shows (name and message, name only, or nothing) and whether it carries the profile photo, with a preview of the result
- A sound of its own for a chat, or silence, from the Sound button in the chat's info panel; Settings › Notifications lists the chats that have one
- Settings › Notifications shows what macOS currently allows this app's notifications to do: banners or alerts, sound, Notification Centre, Lock Screen, badges and previews
- Settings › Privacy lists the app's permissions (notifications, microphone, location) and whether each is granted

## 0.9.1

- Lower memory use. The chat list now builds rows only for the chats near the ones on screen instead of all of them; map previews are saved and shown as pictures instead of loading the map engine each time; the menu bar icon is a small bitmap; the image cache is half the size; the database and the protocol core are held to tighter limits; and with the window closed the open chat's messages are let go until it is shown again

## 0.9.0

- Ready-made themes in Settings › Appearance: Darcula, Dracula, Tokyo Night, Nord, Catppuccin, Gruvbox, One Dark, Monokai, Solarized, GitHub, Rosé Pine, Night Owl, SynthWave '84, Everforest, Ayu Mirage, WhatsApp Dark and light variants. Each sets the background, chat list, bubbles and accent
- More to customise: a third colour in the colour field, a colour of your own for the accent, chat background, chat list and each bubble, and window transparency that lets the desktop show through
- Swipe right with two fingers on a message to reply to it
- Voice messages: click or drag along the bar to move through the recording, pause and carry on where you stopped, and play at 1×, 1.5× or 2×

## 0.8.5

- Save to Downloads: a document in a chat has a download button beside it, which saves the file under its own name; a second click shows it in Finder
- Photos, videos, voice messages and documents can be saved from the message menu: Save to Downloads, or Save As… to choose the place
- A file never overwrites one with the same name; it becomes "Name 2.pdf"

## 0.8.4

- Compact window: a narrow window with a single column, like WhatsApp on the phone. Chats open over the list and ⌘[ (or the arrow beside the name) goes back. Switch it with ⌥⌘C, from View › Compact Mode, or in Settings › Appearance; the window narrows, and widens back when you leave it
- The tighter spacing from 0.8.3 is now called Dense layout and stays in Settings › Appearance

## 0.8.3

- Compact mode for the whole app: smaller chat rows, tighter message bubbles and spacing, and a denser menu bar panel. Switch it in Settings › Appearance, from View › Compact Mode, or with ⌥⌘C

## 0.8.2

- Long messages can be scrolled while you write them: the field grows to eight lines, then scrolls with the mouse or trackpad
- WhatsApp formatting shows in messages: *bold*, _italic_, ~strikethrough~, `code` and ```monospace``` blocks
- Markdown's **bold** (and __italic__, ~~strikethrough~~), common in pasted text, shows as bold and is sent as WhatsApp's *bold*, so the other side sees it too
- Formatting markers are left out of the chat list previews

## 0.8.1

- The + for a new list sits next to Archived instead of starting a line of its own
- A list can keep its chats out of All, so they show only under the list (Unread still shows them): switch it on in the list editor or from the list's right-click menu

## 0.8.0

- Lists: group chats your own way, for example by work or by client. Make one with + next to the filters, pick a name, an emoji and its chats; each list shows how many of its chats are unread
- Add a chat to a list from its right-click menu (Add to List); edit or delete a list from the list's own right-click menu
- The filters wrap onto a second line instead of disappearing off the side, and your lists also appear in the menu bar panel
- Lists are kept on this Mac, separately for each account

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
