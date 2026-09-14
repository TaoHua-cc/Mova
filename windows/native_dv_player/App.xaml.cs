using System.Text.Json;
using Microsoft.UI.Xaml;

namespace Mova.NativeDvPlayer;

public partial class App : Application
{
    private Window? _window;

    public App()
    {
        InitializeComponent();
        UnhandledException += (_, args) =>
        {
            PlaybackResponse.WriteOnce(new PlaybackResponse(Error: "native_player_error"));
            args.Handled = true;
        };
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        try
        {
            var input = Console.In.ReadLine();
            var request = JsonSerializer.Deserialize<PlaybackRequest>(input ?? string.Empty,
                JsonOptions.Default) ?? throw new InvalidDataException();
            if (!Uri.TryCreate(request.Url, UriKind.Absolute, out _))
            {
                throw new InvalidDataException();
            }

            _window = new MainWindow(request);
            _window.Activate();
        }
        catch
        {
            PlaybackResponse.WriteOnce(new PlaybackResponse(Error: "invalid_request"));
            Exit();
        }
    }
}

internal sealed record PlaybackRequest(
    string Url,
    string? Title,
    long PositionMs,
    string? Container,
    bool ExpectedDolbyVision);

internal sealed record PlaybackResponse(
    long PositionMs = 0,
    long DurationMs = 0,
    bool Completed = false,
    bool NativeDolbyVision = false,
    string? Error = null)
{
    private static int _written;

    internal static void WriteOnce(PlaybackResponse response)
    {
        if (Interlocked.Exchange(ref _written, 1) != 0) return;
        Console.Out.WriteLine(JsonSerializer.Serialize(response, JsonOptions.Default));
        Console.Out.Flush();
    }
}

internal static class JsonOptions
{
    internal static readonly JsonSerializerOptions Default = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
    };
}
