using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Windows.Media.Core;
using Windows.Media.Playback;

namespace Mova.NativeDvPlayer;

public sealed partial class MainWindow : Window
{
    private readonly PlaybackRequest _request;
    private readonly MediaPlayer _player;
    private bool _opened;
    private bool _completed;
    private string? _error;

    public MainWindow(PlaybackRequest request)
    {
        _request = request;
        InitializeComponent();
        Title = string.IsNullOrWhiteSpace(request.Title)
            ? "Mova · Dolby Vision"
            : $"Mova · {request.Title}";
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1280, 720));

        _player = new MediaPlayer();
        PlayerElement.SetMediaPlayer(_player);
        _player.MediaOpened += OnMediaOpened;
        _player.MediaEnded += OnMediaEnded;
        _player.MediaFailed += OnMediaFailed;
        Closed += OnClosed;
        _player.Source = MediaSource.CreateFromUri(new Uri(request.Url));
        _player.Play();
    }

    private void OnMediaOpened(MediaPlayer sender, object args)
    {
        _opened = true;
        if (_request.PositionMs > 0)
        {
            sender.PlaybackSession.Position = TimeSpan.FromMilliseconds(_request.PositionMs);
        }
    }

    private void OnMediaEnded(MediaPlayer sender, object args)
    {
        _completed = true;
        WriteResult();
        DispatcherQueue.TryEnqueue(() => Close());
    }

    private void OnMediaFailed(MediaPlayer sender, MediaPlayerFailedEventArgs args)
    {
        _error = args.Error switch
        {
            MediaPlayerError.DecodingError => "decoder_rejected_media",
            MediaPlayerError.SourceNotSupported => "source_not_supported",
            MediaPlayerError.NetworkError => "network_error",
            _ => "media_failed",
        };
        WriteResult();
        DispatcherQueue.TryEnqueue(() => Close());
    }

    private void OnClosed(object sender, WindowEventArgs args)
    {
        WriteResult();
        _player.Dispose();
    }

    private void WriteResult()
    {
        var session = _player.PlaybackSession;
        PlaybackResponse.WriteOnce(new PlaybackResponse(
            PositionMs: (long)session.Position.TotalMilliseconds,
            DurationMs: (long)session.NaturalDuration.TotalMilliseconds,
            Completed: _completed,
            // This means the DV-tagged source was accepted by the native Windows
            // pipeline. Only the OS/display badge can prove DV output engagement.
            NativeDolbyVision: _opened && _request.ExpectedDolbyVision && _error is null,
            Error: _error));
    }
}
