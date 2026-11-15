using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Threading;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace RedCast.Core;

/// <summary>Runs actions one by one on a dedicated background thread.</summary>
public sealed class SerialQueue : IDisposable
{
    readonly BlockingCollection<Action> _items = new();
    readonly Thread _thread;

    public SerialQueue(string name)
    {
        _thread = new Thread(() =>
        {
            foreach (var a in _items.GetConsumingEnumerable())
            {
                try { a(); } catch (Exception ex) { Debug.WriteLine(ex); }
            }
        }) { IsBackground = true, Name = name };
        _thread.Start();
    }

    public void Post(Action a) { if (!_items.IsAddingCompleted) _items.Add(a); }

    public T Invoke<T>(Func<T> f)
    {
        T result = default!;
        using var done = new ManualResetEventSlim();
        Post(() => { try { result = f(); } finally { done.Set(); } });
        done.Wait();
        return result;
    }

    public void Invoke(Action a) => Invoke(() => { a(); return 0; });

    public void Dispose() => _items.CompleteAdding();
}

/// <summary>Averages any number of channels into one.</summary>
sealed class MonoDownmix : ISampleProvider
{
    readonly ISampleProvider _src;
    readonly int _ch;
    float[] _buf = Array.Empty<float>();

    public MonoDownmix(ISampleProvider src)
    {
        _src = src;
        _ch = src.WaveFormat.Channels;
        WaveFormat = WaveFormat.CreateIeeeFloatWaveFormat(src.WaveFormat.SampleRate, 1);
    }

    public WaveFormat WaveFormat { get; }

    public int Read(float[] buffer, int offset, int count)
    {
        int need = count * _ch;
        if (_buf.Length < need) _buf = new float[need];
        int read = _src.Read(_buf, 0, need);
        int frames = read / _ch;
        for (int f = 0; f < frames; f++)
        {
            float sum = 0;
            for (int c = 0; c < _ch; c++) sum += _buf[f * _ch + c];
            buffer[offset + f] = sum / _ch;
        }
        return frames;
    }
}

/// <summary>
/// System sound (loopback: Zoom / Meet / Teams / Telegram / browser) or microphone,
/// converted to 16 kHz mono float — the format Whisper expects.
/// </summary>
public sealed class AudioSource : IDisposable
{
    public event Action<float[]>? Samples;
    public event Action<string>? Failed;
    /// <summary>Input level 0…1 about 10 times per second (meters).</summary>
    public event Action<float>? Level;
    /// <summary>Microphone endpoint id; "" = Windows default.</summary>
    public string DeviceId { get; set; } = "";

    float _peak;
    int _levelCount;

    readonly bool _loopback;
    IWaveIn? _capture;
    BufferedWaveProvider? _buffer;
    ISampleProvider? _pipeline;
    Timer? _silenceTimer;
    readonly object _lock = new();
    readonly Stopwatch _clock = Stopwatch.StartNew();
    double _lastEmitSec;

    public AudioSource(bool loopback) { _loopback = loopback; }

    public bool IsRunning => _capture != null;

    public void Start()
    {
        if (_capture != null) return;
        IWaveIn cap = _loopback ? new WasapiLoopbackCapture() : CreateMic();
        var buffer = new BufferedWaveProvider(cap.WaveFormat)
        {
            DiscardOnBufferOverflow = true,
            BufferDuration = TimeSpan.FromSeconds(10),
            ReadFully = false,
        };
        ISampleProvider sp = buffer.ToSampleProvider();
        if (sp.WaveFormat.Channels > 1) sp = new MonoDownmix(sp);
        if (sp.WaveFormat.SampleRate != 16000) sp = new WdlResamplingSampleProvider(sp, 16000);

        cap.DataAvailable += (_, e) =>
        {
            lock (_lock)
            {
                if (_capture == null) return;
                buffer.AddSamples(e.Buffer, 0, e.BytesRecorded);
                Pump();
                _lastEmitSec = _clock.Elapsed.TotalSeconds;
            }
        };
        cap.RecordingStopped += (_, e) =>
        {
            if (e.Exception != null) Failed?.Invoke(e.Exception.Message);
        };

        _buffer = buffer;
        _pipeline = sp;
        _capture = cap;
        _lastEmitSec = _clock.Elapsed.TotalSeconds;
        cap.StartRecording();

        // WASAPI loopback sends nothing while nothing plays → feed silence so pauses are detected.
        if (_loopback)
            _silenceTimer = new Timer(_ => InjectSilence(), null, 100, 100);
    }

    WasapiCapture CreateMic()
    {
        if (!string.IsNullOrEmpty(DeviceId))
        {
            using var en = new MMDeviceEnumerator();
            MMDevice dev;
            try { dev = en.GetDevice(DeviceId); }
            catch { throw new InvalidOperationException("Выбранный микрофон не найден. Выберите другой в «Настройки → Распознавание речи → Микрофон»."); }
            if (dev.State != DeviceState.Active)
                throw new InvalidOperationException("Выбранный микрофон отключён. Выберите другой в настройках.");
            return new WasapiCapture(dev) { ShareMode = AudioClientShareMode.Shared };
        }
        return new WasapiCapture { ShareMode = AudioClientShareMode.Shared };
    }

    /// <summary>Active microphones: (id, name).</summary>
    public static System.Collections.Generic.List<(string Id, string Name)> Microphones()
    {
        var list = new System.Collections.Generic.List<(string, string)>();
        try
        {
            using var en = new MMDeviceEnumerator();
            foreach (var d in en.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active))
                list.Add((d.ID, d.FriendlyName));
        }
        catch { }
        return list;
    }

    public static string? DefaultMicrophoneName()
    {
        try
        {
            using var en = new MMDeviceEnumerator();
            return en.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Communications).FriendlyName;
        }
        catch { return null; }
    }

    void Pump()
    {
        if (_pipeline == null) return;
        var buf = new float[4096];
        int n;
        while ((n = _pipeline.Read(buf, 0, buf.Length)) > 0)
        {
            var chunk = new float[n];
            Array.Copy(buf, chunk, n);
            Samples?.Invoke(chunk);
            ReportLevel(chunk);
        }
    }

    void ReportLevel(float[] chunk)
    {
        double sum = 0;
        foreach (var s in chunk) sum += s * s;
        _peak = Math.Max(_peak, (float)Math.Sqrt(sum / chunk.Length));
        _levelCount += chunk.Length;
        if (_levelCount >= 1600)
        {
            Level?.Invoke(Math.Min(1f, _peak * 8));
            _peak = 0;
            _levelCount = 0;
        }
    }

    void InjectSilence()
    {
        lock (_lock)
        {
            if (_capture == null) return;
            double now = _clock.Elapsed.TotalSeconds;
            double gap = now - _lastEmitSec;
            if (gap < 0.2) return;
            int count = (int)(gap * 16000);
            if (count > 0) Samples?.Invoke(new float[count]);
            _lastEmitSec = now;
        }
    }

    public void Stop()
    {
        IWaveIn? cap;
        lock (_lock)
        {
            _silenceTimer?.Dispose();
            _silenceTimer = null;
            cap = _capture;
            _capture = null;
            _pipeline = null;
            _buffer = null;
        }
        // Outside the lock: Dispose joins the capture thread, which may be waiting for the lock.
        try { cap?.StopRecording(); } catch { }
        try { cap?.Dispose(); } catch { }
        Level?.Invoke(0);
    }

    public void Dispose() => Stop();
}

/// <summary>Energy voice detector with an adaptive noise floor (16 kHz, 30 ms frames).</summary>
public sealed class VoiceDetector
{
    float _noise = 0.001f;

    public static float Rms(float[] frame)
    {
        double sum = 0;
        foreach (var s in frame) sum += s * s;
        return (float)Math.Sqrt(sum / Math.Max(1, frame.Length));
    }

    /// <summary>adapt — let quiet frames move the noise floor (only while nobody is talking).</summary>
    public bool IsSpeech(float[] frame, bool adapt)
    {
        float rms = Rms(frame);
        bool speech = rms > Math.Max(_noise * 3f, 0.004f);
        if (!speech && adapt) _noise = _noise * 0.97f + rms * 0.03f;
        return speech;
    }
}

/// <summary>
/// Cuts a long phrase into pieces at natural pauses, so each piece is recognised while the person
/// is still talking. When they stop, only the short tail is left to recognise.
/// </summary>
public sealed class ChunkTracker
{
    const int FrameLen = 480;
    /// <summary>A pause this long (360 ms) inside a phrase is a good cut point.</summary>
    public int PauseFrames = 12;
    /// <summary>Only cut once the piece has this much voice (1.8 s): tiny pieces recognise worse.</summary>
    public int MinVoicedFrames = 60;
    /// <summary>Never let a piece grow past this, even without a pause.</summary>
    public int MaxPieceSamples = 16000 * 24;

    public int PieceStart { get; private set; }
    public int VoicedFrames { get; private set; }
    int _silenceRun;
    bool _cutInThisPause;

    public void Reset(int start = 0)
    {
        PieceStart = start;
        VoicedFrames = 0;
        _silenceRun = 0;
        _cutInThisPause = false;
    }

    /// <summary>Call after appending a frame; count = buffer length now. Returns the cut index when a piece is complete.</summary>
    public int? Observe(bool isSpeech, int count)
    {
        if (isSpeech) { VoicedFrames++; _silenceRun = 0; _cutInThisPause = false; }
        else _silenceRun++;
        if (!_cutInThisPause && _silenceRun >= PauseFrames && VoicedFrames >= MinVoicedFrames)
        {
            _cutInThisPause = true;
            // Cut in the middle of the pause: no word is split.
            return Math.Max(PieceStart + 1, count - (_silenceRun / 2) * FrameLen);
        }
        if (count - PieceStart >= MaxPieceSamples && !isSpeech) return count;
        if (count - PieceStart >= MaxPieceSamples + 16000 * 2) return count;   // no quiet frame for 2 s: cut anyway
        return null;
    }

    public void DidCut(int index) { PieceStart = index; VoicedFrames = 0; }

    /// <summary>The rest after the last cut has some voice worth recognising.</summary>
    public bool TailHasVoice => VoicedFrames >= 5;
}

/// <summary>
/// «Авто» mode: splits the stream into phrases (a phrase ends after SilenceMs of silence) and,
/// inside a phrase, into pieces at short pauses. Not thread-safe: feed from one SerialQueue.
/// </summary>
public sealed class SpeechSegmenter
{
    public double SilenceMs = 700;
    public bool Active = true;
    /// <summary>A new phrase started (its id).</summary>
    public Action<int>? OnSpeechStart;
    /// <summary>Audio of the piece being spoken right now (live caption).</summary>
    public Action<int, float[]>? OnPartial;
    /// <summary>A finished piece inside the phrase.</summary>
    public Action<int, float[]>? OnPiece;
    /// <summary>The phrase ended: remaining audio (may be empty) and whether it has voice.</summary>
    public Action<int, float[], bool>? OnFinal;
    /// <summary>The «phrase» was only a click or a breath.</summary>
    public Action<int>? OnDiscard;

    const int SampleRate = 16000, FrameLen = 480; // 30 ms
    const double FrameMs = 30;
    const int PreRollFrames = 10, MaxUtterance = 16000 * 90, PartialEvery = 21000, PartialWindow = 16000 * 8;
    const double MinSpeechMs = 250;

    readonly VoiceDetector _detector = new();
    readonly ChunkTracker _tracker = new();
    readonly System.Collections.Generic.List<float> _pending = new();
    readonly System.Collections.Generic.Queue<float[]> _preRoll = new();
    readonly System.Collections.Generic.List<float> _utt = new();
    bool _inSpeech;
    int _onset, _silence, _speech, _sincePartial, _pieces, _id;

    public void Reset()
    {
        _pending.Clear(); _preRoll.Clear(); _utt.Clear();
        _inSpeech = false; _onset = _silence = _speech = _sincePartial = _pieces = 0;
        _tracker.Reset();
    }

    public void Append(float[] samples)
    {
        if (!Active) return;
        _pending.AddRange(samples);
        int offset = 0;
        while (_pending.Count - offset >= FrameLen)
        {
            Process(_pending.GetRange(offset, FrameLen).ToArray());
            offset += FrameLen;
        }
        if (offset > 0) _pending.RemoveRange(0, offset);
    }

    /// <summary>Force-close the current phrase («ответить сейчас»).</summary>
    public void Flush() { if (_inSpeech) Finish(false); }

    void Process(float[] frame)
    {
        bool isSpeech = _detector.IsSpeech(frame, adapt: !_inSpeech);

        if (_inSpeech)
        {
            _utt.AddRange(frame);
            _sincePartial += frame.Length;
            if (isSpeech) { _silence = 0; _speech++; } else _silence++;
            if (_silence * FrameMs >= SilenceMs) { Finish(true); return; }
            if (_utt.Count >= MaxUtterance) { Finish(false); return; }
            if (_tracker.Observe(isSpeech, _utt.Count) is int cut)
            {
                var piece = _utt.GetRange(_tracker.PieceStart, cut - _tracker.PieceStart).ToArray();
                _tracker.DidCut(cut);
                _pieces++;
                _sincePartial = 0;
                OnPiece?.Invoke(_id, piece);
            }
            else if (_sincePartial >= PartialEvery)
            {
                _sincePartial = 0;
                if (_utt.Count - _tracker.PieceStart >= SampleRate)
                {
                    int start = Math.Max(_tracker.PieceStart, _utt.Count - PartialWindow);
                    OnPartial?.Invoke(_id, _utt.GetRange(start, _utt.Count - start).ToArray());
                }
            }
        }
        else
        {
            _preRoll.Enqueue(frame);
            while (_preRoll.Count > PreRollFrames) _preRoll.Dequeue();
            if (isSpeech)
            {
                _onset++;
                if (_onset >= 3)
                {
                    _inSpeech = true;
                    _utt.Clear();
                    foreach (var f in _preRoll) _utt.AddRange(f);
                    _preRoll.Clear();
                    _speech = _onset; _silence = 0; _sincePartial = 0; _pieces = 0;
                    _tracker.Reset();
                    for (int i = 0; i < _onset; i++) _tracker.Observe(true, _utt.Count);
                    _id++;
                    OnSpeechStart?.Invoke(_id);
                }
            }
            else _onset = 0;
        }
    }

    void Finish(bool bySilence)
    {
        int id = _id;
        double voiced = _speech * FrameMs;
        int start = _tracker.PieceStart;
        var tail = start < _utt.Count ? _utt.GetRange(start, _utt.Count - start).ToArray() : Array.Empty<float>();
        bool tailHasVoice = _tracker.TailHasVoice;
        int sent = _pieces;
        _inSpeech = false; _utt.Clear(); _onset = _silence = _speech = _sincePartial = _pieces = 0;
        _tracker.Reset();
        if (sent == 0 && voiced < MinSpeechMs) { OnDiscard?.Invoke(id); return; }
        // Trim most of the trailing silence (keep 200 ms): less audio, faster decode.
        int trailing = (int)(SilenceMs / 1000 * SampleRate) - SampleRate / 5;
        if (bySilence && trailing > 0 && tail.Length > trailing * 2) Array.Resize(ref tail, tail.Length - trailing);
        OnFinal?.Invoke(id, tailHasVoice ? tail : Array.Empty<float>(), tailHasVoice);
    }
}

/// <summary>
/// «По кнопкам»: records from the 1st press to the 2nd, keeps 1.5 s before the press, and sends
/// finished pieces (at natural pauses) for recognition while the recording goes on.
/// </summary>
public sealed class ManualRecorder
{
    public Action<int, float[]>? OnPartial;
    public Action<int, float[]>? OnPiece;
    const int FrameLen = 480, Preroll = 24000, PartialEvery = 21000;
    readonly VoiceDetector _detector = new();
    readonly ChunkTracker _tracker = new();
    readonly System.Collections.Generic.List<float> _pending = new();
    readonly System.Collections.Generic.List<float> _pre = new();
    readonly System.Collections.Generic.List<float> _buf = new();
    bool _rec;
    int _since, _id;

    public void Append(float[] s)
    {
        _pending.AddRange(s);
        int offset = 0;
        while (_pending.Count - offset >= FrameLen)
        {
            Process(_pending.GetRange(offset, FrameLen).ToArray());
            offset += FrameLen;
        }
        if (offset > 0) _pending.RemoveRange(0, offset);
    }

    void Process(float[] frame)
    {
        bool isSpeech = _detector.IsSpeech(frame, adapt: true);
        if (!_rec)
        {
            _pre.AddRange(frame);
            if (_pre.Count > Preroll) _pre.RemoveRange(0, _pre.Count - Preroll);
            return;
        }
        _buf.AddRange(frame);
        _since += frame.Length;
        if (_tracker.Observe(isSpeech, _buf.Count) is int cut)
        {
            var piece = _buf.GetRange(_tracker.PieceStart, cut - _tracker.PieceStart).ToArray();
            _tracker.DidCut(cut);
            _since = 0;
            OnPiece?.Invoke(_id, piece);
        }
        else if (_since >= PartialEvery)
        {
            _since = 0;
            if (_buf.Count - _tracker.PieceStart >= 16000)
            {
                int start = Math.Max(_tracker.PieceStart, _buf.Count - 16000 * 8);
                OnPartial?.Invoke(_id, _buf.GetRange(start, _buf.Count - start).ToArray());
            }
        }
    }

    public void Start(int id)
    {
        _id = id;
        _buf.Clear(); _buf.AddRange(_pre); _buf.AddRange(_pending);
        _pre.Clear(); _pending.Clear();
        _since = 0;
        _tracker.Reset();
        _rec = true;
    }

    /// <summary>Stops: the audio after the last piece, whether it has voice, whether pieces were sent.</summary>
    public (float[] Tail, bool HasVoice) Stop()
    {
        _rec = false;
        _buf.AddRange(_pending);
        _pending.Clear();
        int start = _tracker.PieceStart;
        var tail = start < _buf.Count ? _buf.GetRange(start, _buf.Count - start).ToArray() : Array.Empty<float>();
        bool piecesSent = start > 0;
        bool hasVoice = !piecesSent || _tracker.TailHasVoice;   // without pieces the whole recording is the tail
        _buf.Clear();
        _tracker.Reset();
        return (tail, hasVoice);
    }

    public void Cancel() { _rec = false; _buf.Clear(); _tracker.Reset(); }
}
