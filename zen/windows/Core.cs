using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.UI.Dispatching;

namespace WhatsAppZen;

/// <summary>
/// The link to the Rust core (zen_core.dll): commands go in as JSON and may
/// block, so they run on the thread pool; events arrive on the core's threads
/// and are handed to the UI thread.
/// </summary>
public static class Core
{
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate void EventCallback(IntPtr json);

    [DllImport("zen_core", CallingConvention = CallingConvention.Cdecl)]
    private static extern void WAStart([MarshalAs(UnmanagedType.LPUTF8Str)] string dataDir, EventCallback callback);

    [DllImport("zen_core", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr WACall([MarshalAs(UnmanagedType.LPUTF8Str)] string request);

    [DllImport("zen_core", CallingConvention = CallingConvention.Cdecl)]
    private static extern void WAFree(IntPtr reply);

    // Kept in a field: the core calls it for as long as the app runs.
    private static EventCallback? callback;
    private static DispatcherQueue? queue;

    public static event Action<JsonElement>? Event;

    public static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        PropertyNameCaseInsensitive = true,
    };

    public static string DataDir =>
        Environment.GetEnvironmentVariable("ZEN_DATA")
        ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "WhatsAppZen");

    public static void Start(DispatcherQueue ui)
    {
        queue = ui;
        callback = pointer =>
        {
            var text = Marshal.PtrToStringUTF8(pointer);
            if (text == null) return;
            JsonElement element;
            try { element = JsonDocument.Parse(text).RootElement.Clone(); } catch { return; }
            queue?.TryEnqueue(() => Event?.Invoke(element));
        };
        Directory.CreateDirectory(DataDir);
        WAStart(DataDir, callback);
    }

    /// <summary>Runs a command and returns its answer; throws with the core's message on failure.</summary>
    public static Task<JsonElement> Call(string account, string cmd, Dictionary<string, object?>? args = null)
    {
        var request = new Dictionary<string, object?>(args ?? new()) { ["cmd"] = cmd, ["account"] = account };
        var text = JsonSerializer.Serialize(request);
        return Task.Run(() =>
        {
            var pointer = WACall(text);
            var reply = Marshal.PtrToStringUTF8(pointer) ?? "{}";
            WAFree(pointer);
            using var document = JsonDocument.Parse(reply);
            var root = document.RootElement;
            if (root.TryGetProperty("error", out var error)) throw new CoreException(error.GetString() ?? "error");
            return root.TryGetProperty("data", out var data) ? data.Clone() : default;
        });
    }

    public static async Task<T?> Get<T>(string account, string cmd, Dictionary<string, object?>? args = null)
    {
        var data = await Call(account, cmd, args);
        return data.ValueKind == JsonValueKind.Undefined ? default : data.Deserialize<T>(Json);
    }

    /// <summary>Runs a command without waiting for it.</summary>
    public static void Fire(string account, string cmd, Dictionary<string, object?>? args = null)
    {
        _ = Call(account, cmd, args).ContinueWith(_ => { }, TaskScheduler.Default);
    }
}

public class CoreException(string message) : Exception(message);

public record Chat
{
    public string Jid { get; init; } = "";
    public string Name { get; init; } = "";
    public bool IsGroup { get; init; }
    public long LastTs { get; init; }
    public long Unread { get; init; }
    public string LastType { get; init; } = "";
    public string LastText { get; init; } = "";
    public bool LastFromMe { get; init; }
    public int LastStatus { get; init; }
    public string LastSender { get; init; } = "";
    public string LastFile { get; init; } = "";
    public bool Archived { get; init; }
    public bool Pinned { get; init; }
    public bool Muted { get; init; }
}

public record Reaction
{
    public string Emoji { get; init; } = "";
    public string Name { get; init; } = "";
    public bool FromMe { get; init; }
}

public record Message
{
    public string Id { get; init; } = "";
    public string Chat { get; init; } = "";
    public string Sender { get; init; } = "";
    public string SenderName { get; init; } = "";
    public bool FromMe { get; init; }
    public long Ts { get; init; }
    [JsonPropertyName("type")] public string Kind { get; init; } = "";
    public string Text { get; init; } = "";
    public string Thumb { get; init; } = "";
    public string MediaPath { get; init; } = "";
    public string FileName { get; init; } = "";
    public long W { get; init; }
    public long H { get; init; }
    public string QuotedId { get; init; } = "";
    public string QuotedText { get; init; } = "";
    public string QuotedSender { get; init; } = "";
    public int Status { get; init; }
    public bool Edited { get; init; }
    public bool Deleted { get; init; }
    public bool MentionsMe { get; init; }
    public List<Reaction> Reactions { get; init; } = [];

    public DateTime Time => DateTimeOffset.FromUnixTimeSeconds(Ts).LocalDateTime;

    /// <summary>Same content, for telling whether the list needs drawing again.</summary>
    public string Key => $"{Id}|{Status}|{Edited}|{Deleted}|{Text}|{MediaPath}|{string.Join(",", Reactions.Select(r => r.Emoji))}";
}

public static class Status
{
    public const int Failed = -1, Pending = 0, Sent = 1, Delivered = 2, Read = 3;
}
