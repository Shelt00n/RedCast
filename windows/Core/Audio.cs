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
    /// <summary>Input level 0…1 about 10 times per second (meter in Settings).</summary>
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
            if (!_loopback) ReportLevel(chunk);
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
        if (!_loopback) Level?.Invoke(0);
    }

    public void Dispose() => Stop();
}

/// <summary>
/// Energy VAD with adaptive noise floor: splits the stream into utterances.
/// Not thread-safe: feed from one SerialQueue.
/// </summary>
public sealed class SpeechSegmenter
{
    public double SilenceMs = 700;
    public bool Active = true;
    public Action<float[]>? OnPartial;
    public Action<float[]>? OnFinal;
    public Action? OnSpeechStart;

    const int SampleRate = 16000, FrameLen = 480; // 30 ms
    const double FrameMs = 30;
    const int PreRollFrames = 10, MaxUtterance = 16000 * 28, PartialEvery = 24000, PartialWindow = 16000 * 8;
    const double MinSpeechMs = 250;

    readonly System.Collections.Generic.List<float> _pending = new();
    readonly System.Collections.Generic.Queue<float[]> _preRoll = new();
    readonly System.Collections.Generic.List<float> _utt = new();
    bool _inSpeech;
    int _onset, _silence, _speech, _sincePartial;
    float _noise = 0.001f;

    public void Reset()
    {
        _pending.Clear(); _preRoll.Clear(); _utt.Clear();
        _inSpeech = false; _onset = _silence = _speech = _sincePartial = 0;
    }

    public void Append(float[] samples)
    {
        if (!Active) return;
        _pending.AddRange(samples);
        int offset = 0;
        while (_pending.Count - offset >= FrameLen)
        {
            var frame = _pending.GetRange(offset, FrameLen).ToArray();
            Process(frame);
            offset += FrameLen;
        }
        if (offset > 0) _pending.RemoveRange(0, offset);
    }

    public void Flush() { if (_inSpeech) Finish(false); }

    void Process(float[] frame)
    {
        double sum = 0;
        foreach (var s in frame) sum += s * s;
        float rms = (float)Math.Sqrt(sum / frame.Length);
        float threshold = Math.Max(_noise * 3f, 0.004f);
        bool isSpeech = rms > threshold;

        if (_inSpeech)
        {
            _utt.AddRange(frame);
            _sincePartial += frame.Length;
            if (isSpeech) { _silence = 0; _speech++; } else _silence++;
            if (_silence * FrameMs >= SilenceMs) Finish(true);
            else if (_utt.Count >= MaxUtterance) Finish(false);
            else if (_sincePartial >= PartialEvery)
            {
                _sincePartial = 0;
                int start = Math.Max(0, _utt.Count - PartialWindow);
                OnPartial?.Invoke(_utt.GetRange(start, _utt.Count - start).ToArray());
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
                    _speech = _onset; _silence = 0; _sincePartial = 0;
                    OnSpeechStart?.Invoke();
                }
            }
            else
            {
                _onset = 0;
                _noise = _noise * 0.97f + rms * 0.03f;
            }
        }
    }

    void Finish(bool bySilence)
    {
        var audio = _utt.ToArray();
        double voiced = _speech * FrameMs;
        _inSpeech = false; _utt.Clear(); _onset = _silence = _speech = _sincePartial = 0;
        if (voiced < MinSpeechMs) return;
        int trailing = (int)(SilenceMs / 1000 * SampleRate) - SampleRate / 5;
        if (bySilence && trailing > 0 && audio.Length > trailing * 2)
            Array.Resize(ref audio, audio.Length - trailing);
        OnFinal?.Invoke(audio);
    }
}

/// <summary>«По кнопкам»: records from 1st press to 2nd press, keeps 1.5 s before the press.</summary>
public sealed class ManualRecorder
{
    public Action<float[]>? OnPartial;
    const int Preroll = 24000, PartialEvery = 24000;
    readonly System.Collections.Generic.List<float> _pre = new();
    readonly System.Collections.Generic.List<float> _buf = new();
    bool _rec;
    int _since;

    public void Append(float[] s)
    {
        if (_rec)
        {
            _buf.AddRange(s);
            _since += s.Length;
            if (_since >= PartialEvery)
            {
                _since = 0;
                int start = Math.Max(0, _buf.Count - 16000 * 8);
                OnPartial?.Invoke(_buf.GetRange(start, _buf.Count - start).ToArray());
            }
        }
        else
        {
            _pre.AddRange(s);
            if (_pre.Count > Preroll) _pre.RemoveRange(0, _pre.Count - Preroll);
        }
    }

    public void Start() { _buf.Clear(); _buf.AddRange(_pre); _pre.Clear(); _since = 0; _rec = true; }
    public float[] Stop() { _rec = false; var a = _buf.ToArray(); _buf.Clear(); return a; }
    public void Cancel() { _rec = false; _buf.Clear(); }
}
