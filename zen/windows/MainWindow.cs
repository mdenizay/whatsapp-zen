using System.Globalization;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Text.Json;
using Microsoft.UI.Input;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;
using Windows.ApplicationModel.DataTransfer;
using Windows.Graphics.Imaging;
using Windows.Storage;
using Windows.Storage.Pickers;
using Windows.Storage.Streams;
using Windows.System;
using Windows.UI.Core;

namespace WhatsAppZen;

/// <summary>The window: pairing, the chat list and the open chat, built in code.</summary>
public sealed class MainWindow : Window
{
    private const int Page = 60;

    private string account = "main";
    private bool connected;
    private List<Chat> chats = [];
    private string? selected;
    private List<Message> messages = [];
    private int limit = Page;
    private Message? replyTo;
    private bool rendering, chatsPending, messagesPending, loadingOlder;
    private readonly Dictionary<string, string?> avatars = [];
    private readonly Dictionary<string, BitmapImage> pictures = [];

    // Pairing.
    private readonly Grid pairing = new();
    private readonly Image qr = new() { Width = 264, Height = 264 };
    private readonly TextBlock pairNote = new() { TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, MaxWidth = 420 };
    private readonly ProgressRing loading = new() { IsActive = true, Width = 40, Height = 40 };

    // Main.
    private readonly Grid main = new() { Visibility = Visibility.Collapsed };
    private readonly TextBox search = new() { PlaceholderText = Strings.T("Search"), Margin = new Thickness(12, 0, 12, 8) };
    private readonly ListView chatList = new() { SelectionMode = ListViewSelectionMode.Single };
    private readonly TextBlock title = new() { FontSize = 16, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly TextBlock subtitle = new() { FontSize = 12, Opacity = 0.7 };
    private readonly ScrollViewer scroller = new() { HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
    private readonly StackPanel list = new() { Spacing = 3, Padding = new Thickness(18, 10, 18, 10) };
    private readonly Grid chatPane = new() { Visibility = Visibility.Collapsed };
    private readonly TextBlock emptyNote = new() { Text = Strings.T("Choose a chat"), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Opacity = 0.6, FontSize = 16 };
    private readonly Grid replyBar = new() { Visibility = Visibility.Collapsed, Padding = new Thickness(14, 6, 8, 6) };
    private readonly TextBlock replyText = new() { TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBox composer = new()
    {
        PlaceholderText = Strings.T("Message"),
        AcceptsReturn = true,
        TextWrapping = TextWrapping.Wrap,
        MaxHeight = 160,
        VerticalAlignment = VerticalAlignment.Bottom,
    };
    private readonly InfoBar info = new() { IsOpen = false, Severity = InfoBarSeverity.Warning, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(12) };

    public MainWindow()
    {
        Title = "WhatsApp Zen";
        SystemBackdrop = new MicaBackdrop();
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1120, 780));
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "app.ico"));
        Content = Build();
        Activated += (_, args) =>
        {
            IsActive = args.WindowActivationState != WindowActivationState.Deactivated;
            if (IsActive && selected != null) MarkRead(selected);
        };
        SetUpNotifications();
        Core.Event += Handle;
        Core.Start(DispatcherQueue);
        _ = StartAsync();
    }

    /// <summary>The window is the one the user is looking at.</summary>
    private bool IsActive;

    private UIElement Build()
    {
        // Pairing.
        var pairStack = new StackPanel { Spacing = 18, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        pairStack.Children.Add(new TextBlock { Text = Strings.T("Link to WhatsApp"), FontSize = 28, FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center });
        pairStack.Children.Add(new TextBlock
        {
            Text = Strings.T("Open WhatsApp on your phone, go to Settings → Linked Devices → Link a Device, and point your phone at this code."),
            TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, MaxWidth = 420, Opacity = 0.8,
        });
        pairStack.Children.Add(new Border { Child = qr, Background = new SolidColorBrush(Microsoft.UI.Colors.White), CornerRadius = new CornerRadius(16), Padding = new Thickness(12), HorizontalAlignment = HorizontalAlignment.Center });
        pairStack.Children.Add(pairNote);
        pairing.Children.Add(pairStack);
        pairing.Visibility = Visibility.Collapsed;

        // Chat list.
        main.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(340) });
        main.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var left = new Grid();
        left.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        left.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        left.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        var heading = new TextBlock { Text = Strings.T("Chats"), FontSize = 20, FontWeight = FontWeights.SemiBold, Margin = new Thickness(16, 14, 16, 10) };
        left.Children.Add(heading);
        Grid.SetRow(search, 1);
        left.Children.Add(search);
        Grid.SetRow(chatList, 2);
        left.Children.Add(chatList);
        search.TextChanged += (_, _) => RenderChats();
        chatList.SelectionChanged += (_, e) =>
        {
            if (rendering || e.AddedItems.Count == 0) return;
            if (e.AddedItems[0] is ListViewItem { Tag: string jid }) Open(jid);
        };
        main.Children.Add(left);

        // The open chat.
        var right = new Grid { BorderThickness = new Thickness(1, 0, 0, 0), BorderBrush = Brush("CardStrokeColorDefaultBrush") };
        Grid.SetColumn(right, 1);
        right.Children.Add(emptyNote);
        chatPane.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        chatPane.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        chatPane.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        chatPane.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var header = new StackPanel { Padding = new Thickness(18, 12, 18, 10), BorderThickness = new Thickness(0, 0, 0, 1), BorderBrush = Brush("CardStrokeColorDefaultBrush") };
        header.Children.Add(title);
        header.Children.Add(subtitle);
        chatPane.Children.Add(header);
        scroller.Content = list;
        scroller.ViewChanged += (_, e) =>
        {
            if (!e.IsIntermediate && scroller.VerticalOffset < 40) LoadOlder();
        };
        Grid.SetRow(scroller, 1);
        chatPane.Children.Add(scroller);

        replyBar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        replyBar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        replyBar.BorderThickness = new Thickness(3, 0, 0, 0);
        replyBar.BorderBrush = Brush("AccentFillColorDefaultBrush");
        replyBar.Children.Add(replyText);
        var closeReply = new Button { Content = new SymbolIcon(Symbol.Cancel), Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0) };
        ToolTipService.SetToolTip(closeReply, Strings.T("Cancel"));
        closeReply.Click += (_, _) => SetReply(null);
        Grid.SetColumn(closeReply, 1);
        replyBar.Children.Add(closeReply);
        Grid.SetRow(replyBar, 2);
        chatPane.Children.Add(replyBar);

        var input = new Grid { ColumnSpacing = 8, Padding = new Thickness(12, 8, 12, 12) };
        input.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        input.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        input.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var attach = new Button { Content = new SymbolIcon(Symbol.Attach), VerticalAlignment = VerticalAlignment.Bottom };
        ToolTipService.SetToolTip(attach, Strings.T("Attach a file"));
        attach.Click += async (_, _) => await AttachAsync();
        input.Children.Add(attach);
        Grid.SetColumn(composer, 1);
        input.Children.Add(composer);
        var send = new Button { Content = new SymbolIcon(Symbol.Send), Style = (Style)Application.Current.Resources["AccentButtonStyle"], VerticalAlignment = VerticalAlignment.Bottom };
        ToolTipService.SetToolTip(send, Strings.T("Send"));
        send.Click += (_, _) => Send();
        Grid.SetColumn(send, 2);
        input.Children.Add(send);
        Grid.SetRow(input, 3);
        chatPane.Children.Add(input);
        // ↩ sends; ⇧↩ starts a new line, as on WhatsApp. Esc drops a reply.
        composer.PreviewKeyDown += (_, e) =>
        {
            var shift = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(CoreVirtualKeyStates.Down);
            if (e.Key == VirtualKey.Enter && !shift)
            {
                e.Handled = true;
                Send();
            }
            else if (e.Key == VirtualKey.Escape && replyTo != null)
            {
                e.Handled = true;
                SetReply(null);
            }
        };
        right.Children.Add(chatPane);
        main.Children.Add(right);

        var root = new Grid();
        root.Children.Add(loading);
        root.Children.Add(pairing);
        root.Children.Add(main);
        root.Children.Add(info);
        // Ctrl+F searches the chats, as everywhere.
        var find = new KeyboardAccelerator { Key = VirtualKey.F, Modifiers = VirtualKeyModifiers.Control };
        find.Invoked += (_, e) =>
        {
            search.Focus(FocusState.Programmatic);
            e.Handled = true;
        };
        root.KeyboardAccelerators.Add(find);
        return root;
    }

    private static Brush Brush(string key) => (Brush)Application.Current.Resources[key];

    private void Toast(string text)
    {
        info.Message = text;
        info.IsOpen = true;
        var timer = DispatcherQueue.CreateTimer();
        timer.Interval = TimeSpan.FromSeconds(5);
        timer.IsRepeating = false;
        timer.Tick += (_, _) => info.IsOpen = false;
        timer.Start();
    }

    private async Task StartAsync()
    {
        try
        {
            await Core.Call("", "set_lang", new() { ["text"] = CultureInfo.CurrentUICulture.TwoLetterISOLanguageName });
            var ids = await Core.Get<List<string>>("", "accounts") ?? [];
            account = ids.FirstOrDefault() ?? "main";
            await Core.Call(account, "open_account");
            Handle(await Core.Call(account, "state"));
        }
        catch (Exception error)
        {
            Toast(error.Message);
        }
    }

    private void Handle(JsonElement e)
    {
        string Text(string key) => e.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? "" : "";
        bool Flag(string key) => e.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.True;
        if (e.ValueKind != JsonValueKind.Object) return;
        if (e.TryGetProperty("account", out var owner) && owner.GetString() != account) return;
        switch (Text("type"))
        {
            case "state":
                switch (Text("state"))
                {
                    case "connected": ShowMain(); break;
                    case "qr": ShowPairing(Text("qr"), ""); break;
                    case "logged_out": ShowPairing("", Strings.T("Logged out. Link this computer again.")); break;
                }
                break;
            case "chats":
                ScheduleChats();
                break;
            case "messages":
                if (Text("chat").Length == 0 || Text("chat") == selected) ScheduleMessages();
                ScheduleChats();
                break;
            case "message":
            {
                var chat = Text("chat");
                ScheduleChats();
                var open = chat == selected;
                if (open)
                {
                    ScheduleMessages();
                    if (IsActive) MarkRead(chat);
                }
                if (Flag("notify") && !(open && IsActive) && e.TryGetProperty("msg", out var raw))
                {
                    var message = raw.Deserialize<Message>(Core.Json);
                    if (message != null) Notify(chat, Text("chat_name"), message);
                }
                break;
            }
            case "typing":
                if (Text("chat") == selected) subtitle.Text = Flag("composing") ? Strings.T("typing…") : "";
                break;
            case "avatar":
                avatars.Remove(Text("jid"));
                break;
        }
    }

    private void ShowPairing(string code, string note)
    {
        connected = false;
        loading.IsActive = false;
        loading.Visibility = Visibility.Collapsed;
        main.Visibility = Visibility.Collapsed;
        pairing.Visibility = Visibility.Visible;
        pairNote.Text = note;
        qr.Source = null;
        if (code.Length > 0)
        {
            var png = new QRCoder.PngByteQRCode(new QRCoder.QRCodeGenerator().CreateQrCode(code, QRCoder.QRCodeGenerator.ECCLevel.L)).GetGraphic(8);
            _ = SetImageAsync(qr, png);
        }
    }

    private void ShowMain()
    {
        var first = !connected;
        connected = true;
        loading.IsActive = false;
        loading.Visibility = Visibility.Collapsed;
        pairing.Visibility = Visibility.Collapsed;
        main.Visibility = Visibility.Visible;
        if (first) ScheduleChats();
    }

    private static async Task SetImageAsync(Image image, byte[] data)
    {
        using var stream = new InMemoryRandomAccessStream();
        await stream.WriteAsync(data.AsBuffer());
        stream.Seek(0);
        var bitmap = new BitmapImage();
        await bitmap.SetSourceAsync(stream);
        image.Source = bitmap;
    }

    // Chats.

    /// <summary>Reloads the chat list soon, once however many events ask for it.</summary>
    private void ScheduleChats()
    {
        if (chatsPending) return;
        chatsPending = true;
        Later(250, async () =>
        {
            chatsPending = false;
            try
            {
                var fresh = await Core.Get<List<Chat>>(account, "chats") ?? [];
                if (!fresh.SequenceEqual(chats))
                {
                    chats = fresh;
                    RenderChats();
                }
            }
            catch (Exception error)
            {
                Toast(error.Message);
            }
        });
    }

    private void Later(int milliseconds, Func<Task> work)
    {
        var timer = DispatcherQueue.CreateTimer();
        timer.Interval = TimeSpan.FromMilliseconds(milliseconds);
        timer.IsRepeating = false;
        timer.Tick += async (_, _) => await work();
        timer.Start();
    }

    private void RenderChats()
    {
        var query = search.Text.Trim().ToLowerInvariant();
        // Archived chats only turn up when searched for.
        var shown = chats.Where(c => query.Length == 0 ? !c.Archived : c.Name.ToLowerInvariant().Contains(query)).Take(300).ToList();
        rendering = true;
        chatList.Items.Clear();
        var index = 0;
        foreach (var chat in shown)
        {
            var item = new ListViewItem { Tag = chat.Jid, Content = ChatRow(chat, index++ < 40), Padding = new Thickness(8, 6, 8, 6) };
            chatList.Items.Add(item);
            if (chat.Jid == selected) chatList.SelectedItem = item;
        }
        rendering = false;
    }

    private Grid ChatRow(Chat chat, bool withPhoto)
    {
        var row = new Grid { ColumnSpacing = 12 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var avatar = new PersonPicture { DisplayName = chat.Name, Width = 44, Height = 44 };
        if (withPhoto) LoadAvatar(avatar, chat.Jid);
        row.Children.Add(avatar);

        var text = new Grid { VerticalAlignment = VerticalAlignment.Center, RowSpacing = 2, ColumnSpacing = 6 };
        text.RowDefinitions.Add(new RowDefinition());
        text.RowDefinitions.Add(new RowDefinition());
        text.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        text.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        text.Children.Add(new TextBlock { Text = chat.Name, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis });
        var time = new TextBlock { Text = Format.Short(chat.LastTs), FontSize = 12, Opacity = 0.65, VerticalAlignment = VerticalAlignment.Center };
        if (chat.Pinned) time.Text = "📌 " + time.Text;
        Grid.SetColumn(time, 1);
        text.Children.Add(time);
        var preview = Format.Preview(chat);
        if (chat.LastFromMe && chat.LastText.Length > 0) preview = Ticks(chat.LastStatus) + " " + preview;
        var line = new TextBlock { Text = preview, Opacity = 0.7, TextTrimming = TextTrimming.CharacterEllipsis, FontSize = 13 };
        Grid.SetRow(line, 1);
        text.Children.Add(line);
        if (chat.Unread > 0)
        {
            var badge = new InfoBadge { Value = (int)Math.Min(chat.Unread, 999), VerticalAlignment = VerticalAlignment.Center };
            Grid.SetRow(badge, 1);
            Grid.SetColumn(badge, 1);
            text.Children.Add(badge);
        }
        else if (chat.Muted)
        {
            var muted = new FontIcon { Glyph = "", FontSize = 12, Opacity = 0.6 };
            Grid.SetRow(muted, 1);
            Grid.SetColumn(muted, 1);
            text.Children.Add(muted);
        }
        Grid.SetColumn(text, 1);
        row.Children.Add(text);
        return row;
    }

    /// <summary>Puts a profile photo on an avatar once known; the core fetches it the first time.</summary>
    private async void LoadAvatar(PersonPicture avatar, string jid)
    {
        if (!avatars.TryGetValue(jid, out var path))
        {
            try
            {
                var value = await Core.Call(account, "avatar", new() { ["jid"] = jid });
                path = value.ValueKind == JsonValueKind.String && value.GetString() is { Length: > 0 } p ? p : null;
            }
            catch { path = null; }
            avatars[jid] = path;
        }
        if (path != null) avatar.ProfilePicture = new BitmapImage(new Uri(path)) { DecodePixelWidth = 88 };
    }

    private static string Ticks(int status) => status switch
    {
        Status.Failed => "⚠",
        Status.Pending => "🕓",
        Status.Sent => "✓",
        _ => "✓✓",
    };

    private void Open(string jid)
    {
        var chat = chats.FirstOrDefault(c => c.Jid == jid);
        if (chat == null) return;
        if (selected != jid)
        {
            selected = jid;
            messages = [];
            limit = Page;
            pictures.Clear();
            SetReply(null);
        }
        title.Text = chat.Name;
        subtitle.Text = "";
        emptyNote.Visibility = Visibility.Collapsed;
        chatPane.Visibility = Visibility.Visible;
        list.Children.Clear();
        composer.Focus(FocusState.Programmatic);
        MarkRead(jid);
        _ = ReloadMessagesAsync(Scroll.End);
    }

    private void MarkRead(string chat)
    {
        if (chats.Any(c => c.Jid == chat && c.Unread > 0)) Core.Fire(account, "mark_read", new() { ["chat"] = chat });
        try { _ = AppNotificationManager.Default.RemoveByTagAsync(Tag(chat)); } catch { }
    }

    // Messages.

    private enum Scroll { End, KeepBottom, Keep }

    private void ScheduleMessages()
    {
        if (messagesPending) return;
        messagesPending = true;
        Later(120, async () =>
        {
            messagesPending = false;
            await ReloadMessagesAsync(Scroll.KeepBottom);
        });
    }

    private void LoadOlder()
    {
        if (loadingOlder || messages.Count < limit) return;
        loadingOlder = true;
        limit += Page;
        _ = ReloadMessagesAsync(Scroll.Keep).ContinueWith(_ => loadingOlder = false, TaskScheduler.FromCurrentSynchronizationContext());
    }

    private async Task ReloadMessagesAsync(Scroll scroll)
    {
        var chat = selected;
        if (chat == null) return;
        List<Message> fresh;
        try { fresh = await Core.Get<List<Message>>(account, "messages", new() { ["chat"] = chat, ["limit"] = limit }) ?? []; }
        catch { return; }
        if (chat != selected || fresh.Select(m => m.Key).SequenceEqual(messages.Select(m => m.Key))) return;
        var atBottom = scroller.VerticalOffset >= scroller.ScrollableHeight - 40;
        var fromBottom = scroller.ExtentHeight - scroller.VerticalOffset;
        messages = fresh;
        RenderMessages();
        scroller.UpdateLayout();
        switch (scroll)
        {
            case Scroll.End:
            case Scroll.KeepBottom when atBottom:
                scroller.ChangeView(null, scroller.ScrollableHeight, null, true);
                break;
            case Scroll.Keep:
                scroller.ChangeView(null, Math.Max(0, scroller.ExtentHeight - fromBottom), null, true);
                break;
        }
    }

    private void RenderMessages()
    {
        list.Children.Clear();
        var isGroup = selected?.EndsWith("@g.us") == true;
        if (messages.Count < limit)
        {
            // Nothing older here; the phone may have more.
            var ask = new HyperlinkButton { Content = Strings.T("Get older messages from your phone"), HorizontalAlignment = HorizontalAlignment.Center };
            ask.Click += (_, _) =>
            {
                if (selected != null) Core.Fire(account, "fetch_history", new() { ["chat"] = selected });
                ask.IsEnabled = false;
            };
            list.Children.Add(ask);
        }
        Message? previous = null;
        for (var i = 0; i < messages.Count; i++)
        {
            var message = messages[i];
            var next = i + 1 < messages.Count ? messages[i + 1] : null;
            if (previous == null || previous.Time.Date != message.Time.Date)
            {
                list.Children.Add(new Border
                {
                    Child = new TextBlock { Text = Format.Day(message.Time), FontSize = 12 },
                    Background = Brush("SubtleFillColorSecondaryBrush"),
                    CornerRadius = new CornerRadius(10),
                    Padding = new Thickness(10, 3, 10, 3),
                    HorizontalAlignment = HorizontalAlignment.Center,
                    Margin = new Thickness(0, 8, 0, 4),
                });
            }
            var firstOfRun = previous == null || previous.Sender != message.Sender || previous.Time.Date != message.Time.Date;
            var lastOfRun = next == null || next.Sender != message.Sender;
            var bubble = Bubble(message, isGroup && !message.FromMe && firstOfRun);
            bubble.Margin = new Thickness(message.FromMe ? 80 : 0, 0, message.FromMe ? 0 : 80, lastOfRun ? 6 : 0);
            list.Children.Add(bubble);
            previous = message;
        }
    }

    private Border Bubble(Message message, bool showSender)
    {
        var mine = message.FromMe;
        var foreground = mine ? Brush("TextOnAccentFillColorPrimaryBrush") : Brush("TextFillColorPrimaryBrush");
        var body = new StackPanel { Spacing = 4 };
        var bubble = new Border
        {
            Child = body,
            CornerRadius = new CornerRadius(14),
            Padding = new Thickness(11, 6, 11, 6),
            Background = mine ? Brush("AccentFillColorDefaultBrush") : Brush("CardBackgroundFillColorDefaultBrush"),
            BorderBrush = message.MentionsMe ? Brush("AccentFillColorDefaultBrush") : Brush("CardStrokeColorDefaultBrush"),
            BorderThickness = new Thickness(message.MentionsMe ? 1.5 : (mine ? 0 : 1)),
            HorizontalAlignment = mine ? HorizontalAlignment.Right : HorizontalAlignment.Left,
            MaxWidth = 560,
        };
        if (showSender)
        {
            body.Children.Add(new TextBlock { Text = message.SenderName, FontSize = 12, FontWeight = FontWeights.SemiBold, Foreground = Brush("AccentTextFillColorPrimaryBrush") });
        }
        if (message.QuotedId.Length > 0)
        {
            var quote = new StackPanel { Spacing = 1 };
            quote.Children.Add(new TextBlock { Text = message.QuotedSender, FontSize = 12, FontWeight = FontWeights.SemiBold, Foreground = foreground, TextTrimming = TextTrimming.CharacterEllipsis });
            quote.Children.Add(new TextBlock { Text = Format.Plain(message.QuotedText), FontSize = 13, Foreground = foreground, Opacity = 0.85, MaxLines = 2, TextWrapping = TextWrapping.Wrap, TextTrimming = TextTrimming.CharacterEllipsis });
            body.Children.Add(new Border
            {
                Child = quote,
                BorderBrush = foreground,
                BorderThickness = new Thickness(3, 0, 0, 0),
                CornerRadius = new CornerRadius(6),
                Padding = new Thickness(8, 3, 8, 3),
                Background = new SolidColorBrush(Windows.UI.Color.FromArgb(24, 128, 128, 128)),
            });
        }
        var text = message.Text;
        if (message.Deleted)
        {
            body.Children.Add(new TextBlock { Text = Strings.T("This message was deleted"), FontStyle = Windows.UI.Text.FontStyle.Italic, Foreground = foreground, Opacity = 0.75 });
            text = "";
        }
        else
        {
            switch (message.Kind)
            {
                case "image":
                case "sticker":
                    body.Children.Add(Photo(message));
                    break;
                case "video":
                case "document":
                case "audio":
                    body.Children.Add(FileButton(message, foreground));
                    break;
                case "poll":
                    text = "📊 " + message.Text;
                    break;
            }
        }
        if (text.Length > 0)
        {
            var block = new TextBlock { TextWrapping = TextWrapping.Wrap, Foreground = foreground, FontSize = 14 };
            foreach (var inline in Format.Inlines(text))
            {
                if (inline is Microsoft.UI.Xaml.Documents.Hyperlink link) link.Foreground = foreground;
                block.Inlines.Add(inline);
            }
            body.Children.Add(block);
        }
        var meta = (message.Edited ? Strings.T("edited") + "  " : "") + Format.Time(message.Ts) + (mine ? "  " + Ticks(message.Status) : "");
        body.Children.Add(new TextBlock
        {
            Text = meta,
            FontSize = 11,
            Foreground = mine && message.Status == Status.Read ? new SolidColorBrush(Windows.UI.Color.FromArgb(255, 166, 233, 255)) : foreground,
            Opacity = 0.75,
            HorizontalAlignment = HorizontalAlignment.Right,
        });
        if (message.Reactions.Count > 0)
        {
            var words = message.Reactions.GroupBy(r => r.Emoji).Select(g => g.Count() > 1 ? $"{g.Key} {g.Count()}" : g.Key);
            body.Children.Add(new TextBlock { Text = string.Join("  ", words), Foreground = foreground });
        }
        bubble.ContextFlyout = Menu(message);
        bubble.DoubleTapped += (_, _) => SetReply(message);
        return bubble;
    }

    private FrameworkElement Photo(Message message)
    {
        double w = message.W > 0 && message.H > 0 ? message.W : 1, h = message.W > 0 && message.H > 0 ? message.H : 1;
        var aspect = w / h;
        var width = message.Kind == "sticker" ? 140 : Math.Clamp(260 * aspect, 150, 300);
        var height = Math.Min(360, width / aspect);
        var image = new Image { Width = width, Height = height, Stretch = message.Kind == "sticker" ? Stretch.Uniform : Stretch.UniformToFill };
        if (pictures.TryGetValue(message.MediaPath, out var known))
        {
            image.Source = known;
        }
        else
        {
            if (message.Thumb.Length > 0)
            {
                try { _ = SetImageAsync(image, Convert.FromBase64String(message.Thumb)); } catch { }
            }
            _ = ShowFullAsync(image, message);
        }
        image.Tapped += (_, _) => _ = OpenMediaAsync(message);
        return new Border { Child = image, CornerRadius = new CornerRadius(10) };
    }

    /// <summary>The picture itself, downloaded if need be; the small preview shows meanwhile.</summary>
    private async Task ShowFullAsync(Image image, Message message)
    {
        var path = await DownloadAsync(message);
        if (path == null) return;
        var bitmap = new BitmapImage(new Uri(path)) { DecodePixelWidth = 600 };
        // About as many as a chat shows at once.
        if (pictures.Count >= 48) pictures.Clear();
        pictures[message.MediaPath.Length > 0 ? message.MediaPath : path] = bitmap;
        image.Source = bitmap;
    }

    private Button FileButton(Message message, Brush foreground)
    {
        var (glyph, label) = message.Kind switch
        {
            "video" => ("", Strings.T("Video")),
            "audio" => ("", Strings.T("Voice message")),
            _ => ("", message.FileName.Length > 0 ? message.FileName : Strings.T("Document")),
        };
        var caption = new TextBlock { Text = label, Foreground = foreground, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
        var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        content.Children.Add(new FontIcon { Glyph = glyph, Foreground = foreground });
        content.Children.Add(caption);
        var button = new Button { Content = content, Background = new SolidColorBrush(Windows.UI.Color.FromArgb(28, 128, 128, 128)), BorderThickness = new Thickness(0) };
        button.Click += async (_, _) =>
        {
            caption.Text = Strings.T("Downloading…");
            await OpenMediaAsync(message);
            caption.Text = label;
        };
        return button;
    }

    private async Task<string?> DownloadAsync(Message message)
    {
        if (message.MediaPath.Length > 0 && File.Exists(message.MediaPath)) return message.MediaPath;
        try
        {
            var value = await Core.Call(account, "download", new() { ["chat"] = message.Chat, ["id"] = message.Id });
            return value.ValueKind == JsonValueKind.String && value.GetString() is { Length: > 0 } path ? path : null;
        }
        catch
        {
            return null;
        }
    }

    private async Task OpenMediaAsync(Message message)
    {
        var path = await DownloadAsync(message);
        if (path == null)
        {
            Toast(Strings.T("The file could not be downloaded"));
            return;
        }
        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(path) { UseShellExecute = true });
    }

    private MenuFlyout Menu(Message message)
    {
        var menu = new MenuFlyout();
        void Item(string text, string glyph, Action action)
        {
            var item = new MenuFlyoutItem { Text = text, Icon = new FontIcon { Glyph = glyph } };
            item.Click += (_, _) => action();
            menu.Items.Add(item);
        }
        if (!message.Deleted)
        {
            var react = new MenuFlyoutSubItem { Text = Strings.T("React"), Icon = new FontIcon { Glyph = "" } };
            foreach (var emoji in new[] { "👍", "❤️", "😂", "😮", "😢", "🙏" })
            {
                var item = new MenuFlyoutItem { Text = emoji };
                item.Click += (_, _) => Core.Fire(account, "react", new() { ["chat"] = message.Chat, ["id"] = message.Id, ["emoji"] = emoji });
                react.Items.Add(item);
            }
            menu.Items.Add(react);
            Item(Strings.T("Reply"), "", () => SetReply(message));
        }
        if (message.Text.Length > 0 && !message.Deleted)
        {
            Item(Strings.T("Copy"), "", () =>
            {
                var package = new DataPackage();
                package.SetText(Format.Plain(message.Text));
                Clipboard.SetContent(package);
            });
        }
        if (!message.Deleted && message.Kind is "image" or "video" or "document" or "audio" or "sticker")
        {
            Item(Strings.T("Open"), "", () => _ = OpenMediaAsync(message));
            Item(Strings.T("Save to Downloads"), "", async () =>
            {
                var path = await DownloadAsync(message);
                Toast(path != null && SaveToDownloads(path, message.FileName) ? Strings.T("Saved to Downloads") : Strings.T("The file could not be downloaded"));
            });
        }
        menu.Items.Add(new MenuFlyoutSeparator());
        Item(Strings.T("Delete for Me"), "", () => Core.Fire(account, "delete_for_me", new() { ["chat"] = message.Chat, ["id"] = message.Id }));
        if (message.FromMe && !message.Deleted)
        {
            Item(Strings.T("Delete for Everyone"), "", () => Core.Fire(account, "revoke", new() { ["chat"] = message.Chat, ["id"] = message.Id }));
        }
        return menu;
    }

    private static bool SaveToDownloads(string path, string name)
    {
        try
        {
            var folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
            Directory.CreateDirectory(folder);
            name = name.Length > 0 ? string.Join("_", name.Split(Path.GetInvalidFileNameChars())) : Path.GetFileName(path);
            var (stem, ext) = (Path.GetFileNameWithoutExtension(name), Path.GetExtension(name));
            var target = Path.Combine(folder, name);
            for (var n = 2; File.Exists(target); n++) target = Path.Combine(folder, $"{stem} ({n}){ext}");
            File.Copy(path, target);
            return true;
        }
        catch
        {
            return false;
        }
    }

    private void SetReply(Message? message)
    {
        replyTo = message;
        if (message == null)
        {
            replyBar.Visibility = Visibility.Collapsed;
            return;
        }
        var who = message.FromMe ? Strings.T("You") : message.SenderName;
        var what = message.Text.Length > 0 ? Format.Plain(message.Text) : Format.KindLabel(message.Kind, message.FileName);
        replyText.Inlines.Clear();
        replyText.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = who + "  ", FontWeight = FontWeights.SemiBold });
        replyText.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = what.Split('\n')[0] });
        replyBar.Visibility = Visibility.Visible;
        composer.Focus(FocusState.Programmatic);
    }

    private async void Send()
    {
        var text = composer.Text.Replace("\r\n", "\n").Replace('\r', '\n').Trim();
        var chat = selected;
        if (chat == null || text.Length == 0) return;
        var reply = replyTo?.Id ?? "";
        composer.Text = "";
        SetReply(null);
        try
        {
            await Core.Call(account, "send_text", new() { ["chat"] = chat, ["text"] = Format.Normalized(text), ["reply_to"] = reply });
        }
        catch (Exception error)
        {
            Toast($"{Strings.T("Could not send")}: {error.Message}");
        }
        await ReloadMessagesAsync(Scroll.End);
    }

    private async Task AttachAsync()
    {
        var chat = selected;
        if (chat == null) return;
        var picker = new FileOpenPicker();
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        var file = await picker.PickSingleFileAsync();
        if (file == null) return;
        var reply = replyTo?.Id ?? "";
        SetReply(null);
        var ext = Path.GetExtension(file.Path).ToLowerInvariant();
        try
        {
            if (ext is ".jpg" or ".jpeg" or ".png" or ".webp" or ".bmp")
            {
                var (jpeg, thumb, w, h) = await PhotoForSendingAsync(file);
                try
                {
                    await Core.Call(account, "send_image", new() { ["chat"] = chat, ["path"] = jpeg, ["thumb"] = thumb, ["w"] = w, ["h"] = h, ["reply_to"] = reply });
                }
                finally
                {
                    File.Delete(jpeg);
                }
            }
            else
            {
                var video = ext is ".mp4" or ".mov" or ".m4v";
                await Core.Call(account, "send_file", new()
                {
                    ["chat"] = chat, ["path"] = file.Path, ["file_name"] = file.Name, ["mime"] = Mime(ext),
                    ["kind"] = video ? "video" : "document", ["reply_to"] = reply,
                });
            }
        }
        catch (Exception error)
        {
            Toast($"{Strings.T("Could not send")}: {error.Message}");
        }
        await ReloadMessagesAsync(Scroll.End);
    }

    private static string Mime(string ext) => ext switch
    {
        ".pdf" => "application/pdf",
        ".mp4" or ".m4v" => "video/mp4",
        ".mov" => "video/quicktime",
        ".zip" => "application/zip",
        ".txt" => "text/plain",
        ".doc" => "application/msword",
        ".docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        ".xls" => "application/vnd.ms-excel",
        ".xlsx" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        ".ppt" => "application/vnd.ms-powerpoint",
        ".pptx" => "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        ".mp3" => "audio/mpeg",
        ".gif" => "image/gif",
        _ => "application/octet-stream",
    };

    /// <summary>A photo as WhatsApp wants it: a JPEG of at most 1600 pixels, a small preview, and its size.</summary>
    private static async Task<(string Path, string Thumb, uint W, uint H)> PhotoForSendingAsync(StorageFile file)
    {
        using var stream = await file.OpenAsync(FileAccessMode.Read);
        var decoder = await BitmapDecoder.CreateAsync(stream);

        async Task<(byte[] Data, uint W, uint H)> Encode(uint longEdge, float quality)
        {
            var scale = Math.Min(1.0, (double)longEdge / Math.Max(decoder.PixelWidth, decoder.PixelHeight));
            var transform = new BitmapTransform
            {
                ScaledWidth = (uint)Math.Max(1, decoder.PixelWidth * scale),
                ScaledHeight = (uint)Math.Max(1, decoder.PixelHeight * scale),
                InterpolationMode = BitmapInterpolationMode.Fant,
            };
            using var bitmap = await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore, transform,
                ExifOrientationMode.RespectExifOrientation, ColorManagementMode.ColorManageToSRgb);
            using var output = new InMemoryRandomAccessStream();
            var options = new BitmapPropertySet { ["ImageQuality"] = new BitmapTypedValue(quality, Windows.Foundation.PropertyType.Single) };
            var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.JpegEncoderId, output, options);
            encoder.SetSoftwareBitmap(bitmap);
            await encoder.FlushAsync();
            var data = new byte[output.Size];
            using var reader = new DataReader(output.GetInputStreamAt(0));
            await reader.LoadAsync((uint)output.Size);
            reader.ReadBytes(data);
            return (data, (uint)bitmap.PixelWidth, (uint)bitmap.PixelHeight);
        }

        var (jpeg, w, h) = await Encode(1600, 0.82f);
        var (thumb, _, _) = await Encode(72, 0.6f);
        var path = Path.Combine(Path.GetTempPath(), $"zen-photo-{Guid.NewGuid():N}.jpg");
        await File.WriteAllBytesAsync(path, jpeg);
        return (path, Convert.ToBase64String(thumb), w, h);
    }

    // Notifications.

    private static string Tag(string chat) => "c" + (uint)chat.GetHashCode();

    private void SetUpNotifications()
    {
        try
        {
            AppNotificationManager.Default.NotificationInvoked += (_, args) =>
            {
                if (!args.Arguments.TryGetValue("chat", out var chat)) return;
                DispatcherQueue.TryEnqueue(() =>
                {
                    Activate();
                    Open(chat);
                });
            };
            AppNotificationManager.Default.Register();
            Closed += (_, _) =>
            {
                try { AppNotificationManager.Default.Unregister(); } catch { }
            };
        }
        catch
        {
            // Notifications are a nicety; the app works without them.
        }
    }

    private void Notify(string chat, string chatName, Message message)
    {
        try
        {
            var body = message.Text.Length > 0 ? Format.Plain(message.Text) : Format.KindLabel(message.Kind, message.FileName);
            if (chat.EndsWith("@g.us") && message.SenderName.Length > 0) body = $"{message.SenderName}: {body}";
            var notification = new AppNotificationBuilder()
                .AddArgument("chat", chat)
                .AddText(chatName.Length > 0 ? chatName : Strings.T("New message"))
                .AddText(body)
                .SetTag(Tag(chat))
                .BuildNotification();
            AppNotificationManager.Default.Show(notification);
        }
        catch
        {
        }
    }
}
