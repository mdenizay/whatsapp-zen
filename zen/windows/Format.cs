using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml.Documents;
using Windows.UI.Text;

namespace WhatsAppZen;

/// <summary>
/// WhatsApp's text formatting: *bold*, _italic_, ~strikethrough~, `code` and
/// ```monospace``` blocks, with links made clickable. Markers only count at
/// word edges, as on the phone. The same rules as the macOS and Linux apps.
/// </summary>
public static partial class Format
{
    private record struct Piece(string Text, bool Bold, bool Italic, bool Strike, bool Code, string? Link);

    [GeneratedRegex(@"(?<=^|[\s(<\[""'])(https?://|www\.)\S+", RegexOptions.IgnoreCase)]
    private static partial Regex LinkPattern();

    /// <summary>Markdown's doubled markers as WhatsApp's single ones.</summary>
    public static string Normalized(string text)
    {
        foreach (var marker in new[] { "**", "__", "~~" })
        {
            var single = marker[..1];
            text = Regex.Replace(text, Regex.Escape(marker) + @"(?=\S)([^\n]+?)(?<=\S)" + Regex.Escape(marker), single + "$1" + single);
        }
        return text;
    }

    private static List<Piece> Parse(string raw)
    {
        var text = Normalized(raw);
        var links = new List<(int Start, int End)>();
        foreach (Match match in LinkPattern().Matches(text))
        {
            var end = match.Index + match.Length;
            while (end > match.Index && ".,;:!?)\"'".Contains(text[end - 1])) end--;
            links.Add((match.Index, end));
        }
        bool InLink(int i) => links.Any(l => i >= l.Start && i < l.End);
        static bool Word(char c) => char.IsLetterOrDigit(c);
        var pieces = new List<Piece>();

        void Emit(int lo, int hi, Piece style)
        {
            var i = lo;
            while (i < hi)
            {
                var link = links.FirstOrDefault(l => i >= l.Start && i < l.End);
                if (link != default)
                {
                    var end = Math.Min(hi, link.End);
                    var target = text[link.Start..link.End];
                    pieces.Add(style with { Text = text[i..end], Link = target.StartsWith("www.", StringComparison.OrdinalIgnoreCase) ? "https://" + target : target });
                    i = end;
                }
                else
                {
                    var next = links.Where(l => l.Start > i).Select(l => l.Start).DefaultIfEmpty(hi).Min();
                    next = Math.Min(next, hi);
                    pieces.Add(style with { Text = text[i..next] });
                    i = next;
                }
            }
        }

        int? Closing(char marker, int i, int hi)
        {
            if (i > 0 && Word(text[i - 1])) return null;
            if (i + 1 >= hi || char.IsWhiteSpace(text[i + 1]) || text[i + 1] == marker) return null;
            for (var j = i + 2; j < hi; j++)
            {
                if (text[j] == '\n') return null;
                if (text[j] == marker && !char.IsWhiteSpace(text[j - 1]) && (j + 1 == hi || !Word(text[j + 1])) && !InLink(j)) return j;
            }
            return null;
        }

        void Walk(int lo, int hi, Piece style)
        {
            var i = lo;
            var plain = lo;
            while (i < hi)
            {
                var c = text[i];
                if (!"*_~`".Contains(c) || InLink(i)) { i++; continue; }
                if (c == '`' && i + 2 < hi && text[i + 1] == '`' && text[i + 2] == '`')
                {
                    var k = i + 3;
                    while (k + 2 < hi && !(text[k] == '`' && text[k + 1] == '`' && text[k + 2] == '`')) k++;
                    if (k + 2 < hi && k > i + 3)
                    {
                        Emit(plain, i, style);
                        pieces.Add(style with { Text = text[(i + 3)..k], Code = true });
                        i = k + 3;
                        plain = i;
                        continue;
                    }
                    i += 3;
                    continue;
                }
                if (Closing(c, i, hi) is not int j) { i++; continue; }
                Emit(plain, i, style);
                switch (c)
                {
                    case '*': Walk(i + 1, j, style with { Bold = true }); break;
                    case '_': Walk(i + 1, j, style with { Italic = true }); break;
                    case '~': Walk(i + 1, j, style with { Strike = true }); break;
                    default: pieces.Add(style with { Text = text[(i + 1)..j], Code = true }); break;
                }
                i = j + 1;
                plain = i;
            }
            Emit(plain, hi, style);
        }

        Walk(0, text.Length, new Piece("", false, false, false, false, null));
        return pieces;
    }

    /// <summary>The text as inlines for a TextBlock.</summary>
    public static IEnumerable<Inline> Inlines(string raw)
    {
        foreach (var piece in Parse(raw))
        {
            var run = new Run { Text = piece.Text };
            if (piece.Bold) run.FontWeight = FontWeights.SemiBold;
            if (piece.Italic) run.FontStyle = FontStyle.Italic;
            if (piece.Strike) run.TextDecorations = TextDecorations.Strikethrough;
            if (piece.Code) run.FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Cascadia Mono, Consolas");
            if (piece.Link != null && Uri.TryCreate(piece.Link, UriKind.Absolute, out var uri))
            {
                var link = new Hyperlink { NavigateUri = uri };
                link.Inlines.Add(run);
                yield return link;
            }
            else
            {
                yield return run;
            }
        }
    }

    /// <summary>The text without its markers, for one-line previews.</summary>
    public static string Plain(string raw)
    {
        var builder = new StringBuilder();
        foreach (var piece in Parse(raw)) builder.Append(piece.Text);
        return builder.ToString();
    }

    public static string Time(long ts) => DateTimeOffset.FromUnixTimeSeconds(ts).LocalDateTime.ToString("HH:mm", CultureInfo.CurrentCulture);

    /// <summary>"Today", "Yesterday" or the date, for day dividers.</summary>
    public static string Day(DateTime date)
    {
        if (date.Date == DateTime.Today) return Strings.T("Today");
        if (date.Date == DateTime.Today.AddDays(-1)) return Strings.T("Yesterday");
        return date.ToString("d MMMM yyyy", CultureInfo.CurrentCulture);
    }

    /// <summary>For the chat list: the time today, "Yesterday", or the date.</summary>
    public static string Short(long ts)
    {
        if (ts <= 0) return "";
        var date = DateTimeOffset.FromUnixTimeSeconds(ts).LocalDateTime;
        if (date.Date == DateTime.Today) return date.ToString("HH:mm", CultureInfo.CurrentCulture);
        if (date.Date == DateTime.Today.AddDays(-1)) return Strings.T("Yesterday");
        return date.ToString("d", CultureInfo.CurrentCulture);
    }

    public static string KindLabel(string kind, string fileName) => kind switch
    {
        "image" => "📷 " + Strings.T("Photo"),
        "video" => "🎥 " + Strings.T("Video"),
        "audio" => "🎤 " + Strings.T("Voice message"),
        "sticker" => "💟 " + Strings.T("Sticker"),
        "document" => "📄 " + (fileName.Length > 0 ? fileName : Strings.T("Document")),
        "poll" => "📊 " + Strings.T("Poll"),
        _ => "",
    };

    public static string Preview(Chat chat)
    {
        string body;
        if (chat.LastType == "deleted") body = Strings.T("This message was deleted");
        else if (chat.LastText.Length == 0 || (chat.LastType != "text" && chat.LastType != "other"))
        {
            var label = KindLabel(chat.LastType, chat.LastFile);
            body = chat.LastText.Length == 0 || chat.LastType == "document" ? label : label + " " + Plain(chat.LastText);
        }
        else body = Plain(chat.LastText);
        body = body.Split('\n')[0];
        return chat.IsGroup && !chat.LastFromMe && chat.LastSender.Length > 0 ? $"{chat.LastSender}: {body}" : body;
    }
}

/// <summary>The app's words: English and Turkish for now.</summary>
public static class Strings
{
    public static readonly bool Turkish = CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "tr";

    private static readonly Dictionary<string, string> Tr = new()
    {
        ["Chats"] = "Sohbetler",
        ["Search"] = "Ara",
        ["Message"] = "Mesaj",
        ["Send"] = "Gönder",
        ["Attach a file"] = "Dosya ekle",
        ["Reply"] = "Yanıtla",
        ["Copy"] = "Kopyala",
        ["React"] = "Tepki ver",
        ["Delete for Me"] = "Benden sil",
        ["Delete for Everyone"] = "Herkesten sil",
        ["Open"] = "Aç",
        ["Save to Downloads"] = "İndirilenlere kaydet",
        ["Saved to Downloads"] = "İndirilenlere kaydedildi",
        ["Link to WhatsApp"] = "WhatsApp'a bağlan",
        ["Open WhatsApp on your phone, go to Settings → Linked Devices → Link a Device, and point your phone at this code."] =
            "Telefonunuzda WhatsApp'ı açın, Ayarlar → Bağlı Cihazlar → Cihaz Bağla'ya gidin ve telefonunuzu bu koda tutun.",
        ["Connecting…"] = "Bağlanıyor…",
        ["Choose a chat"] = "Bir sohbet seçin",
        ["Photo"] = "Fotoğraf",
        ["Video"] = "Video",
        ["Voice message"] = "Sesli mesaj",
        ["Sticker"] = "Çıkartma",
        ["Document"] = "Belge",
        ["Poll"] = "Anket",
        ["This message was deleted"] = "Bu mesaj silindi",
        ["You"] = "Siz",
        ["edited"] = "düzenlendi",
        ["Today"] = "Bugün",
        ["Yesterday"] = "Dün",
        ["typing…"] = "yazıyor…",
        ["Cancel"] = "Vazgeç",
        ["Could not send"] = "Gönderilemedi",
        ["Downloading…"] = "İndiriliyor…",
        ["The file could not be downloaded"] = "Dosya indirilemedi",
        ["Get older messages from your phone"] = "Eski mesajları telefondan iste",
        ["Logged out. Link this computer again."] = "Oturum kapandı. Bu bilgisayarı yeniden bağlayın.",
        ["New message"] = "Yeni mesaj",
    };

    public static string T(string key) => Turkish && Tr.TryGetValue(key, out var value) ? value : key;
}
