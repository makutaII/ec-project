#!/usr/bin/env python3
"""slice_by_sheet: подготовка звуковых файлов из ленты-образца (ATTN_26 §26.6, этап S0).

Запуск из корня репозитория. Godot не нужен. Нужны Python 3.8+, numpy и ffmpeg/ffprobe в PATH.

    # 1. Новая лента: что в ней есть (тишина, ровные участки, всплески) + заготовка листа меток и спектрограмма
    python tools/sound/slice_by_sheet.py analyze data/sounds/sample.mp3 --out data/sounds/sample.sheet.json --spectrogram sample.png

    # 2. Лист меток отредактирован: проверка без записи
    python tools/sound/slice_by_sheet.py slice data/sounds/Diesel_Loco_M44_MAV_III_52380.sheet.json --dry-run

    # 3. Нарезка: клипы (WAV или OGG), петли с кроссфейдом, manifest.json с числами для алгоритма
    python tools/sound/slice_by_sheet.py slice data/sounds/Diesel_Loco_M44_MAV_III_52380.sheet.json
    python tools/sound/slice_by_sheet.py slice <лист> --only eng_notch_a eng_idle_b --format ogg

Лист меток (`*.sheet.json`) лежит рядом с исходником и описывает «как устроена лента», звук не копирует:

    {
      "id": "loco_m44",                      # имя папки результата (рядом с листом) и префикс в manifest
      "source": "Diesel_Loco_M44_MAV_III_52380.mp3",   # путь от папки листа
      "reference": "eng_idle_b",             # регион, относительно которого считается ratio_to_reference
      "defaults": {"fade_in_ms": 5, "fade_out_ms": 40, "xfade_ms": 400, "snap_ms": 150},
      "regions": [
        {"id": "eng_idle_b", "kind": "loop", "start": 65.0, "end": 71.0, "tags": ["engine"]},
        {"id": "horn_low", "kind": "oneshot", "start": 11.36, "end": 13.75, "tags": ["horn"]}
      ]
    }

Виды регионов (`kind`): `oneshot` (разовый звук), `loop` (бесшовная петля), `ramp` (переход: набор или спад оборотов).
Необязательные поля региона: `tags`, `gain_db` (добавка к общему усилению), `fade_in_ms`, `fade_out_ms`,
`xfade_ms` и `snap_ms` (только для петель), `curve` (`auto`: мощность кроссфейда постоянна при измеренной корреляции, `power`, `linear`), `band_hz` ([от, до], Гц: полоса поиска линии
оборотов для этого региона; для всего листа `line_band_hz`, по умолчанию [800, 2500]), `note`.
Границы можно давать в секундах числом или строкой «м:с.д» (например "1:01.7").

Что делает `slice`:
  * ключевое правило: усиление ОБЩЕЕ для всех регионов листа (самый громкий пик встаёт на `--peak-dbfs`, по умолчанию -3),
    поэтому разница уровней между слоями (ступень B громче холостого хода) сохраняется;
  * oneshot и ramp получают короткие плавные края (без щелчков), петля получает кроссфейд ВНУТРИ региона:
    результат короче региона на `xfade_ms`, звук за границами региона не подмешивается;
  * конец петли подбирается внутри региона (не дальше `snap_ms` от его конца) по максимуму корреляции с началом: фазы складываются;
  * формат WAV (16 бит, моно): у петель пишется блок `smpl`, который Godot читает как петлю; формат OGG (`--format ogg`,
    нужен libvorbis в ffmpeg) петель в файле не хранит: границы лежат в manifest.json, включать зацикливание нужно в коде;
  * `manifest.json`: длительность, уровень, пик, доминирующая линия `dominant_hz` в полосе `band_hz` (для настройки pitch слоёв),
    список сильнейших линий `top_hz` во всей полосе 100-6000 Гц, отношение к опорному региону, параметры шва петли и предупреждения.
    Доминирующая линия это максимум спектра в полосе, а не отслеживание оборотов: если в полосе есть гармоники сильнее линии
    (у ступени 5 ленты 34000_56480 линия 1969 Гц слабее пары 739/1478 Гц), полосу региона сужают через `band_hz`.

Код возврата 1, если есть хотя бы одна ошибка (WARN код возврата не меняют).
"""
import argparse
import json
import math
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile

try:
    import numpy as np
except ImportError:  # pragma: no cover
    sys.exit("нужен numpy: pip install numpy")

ID_RE = re.compile(r"^[a-z][a-z0-9_]*$")
KINDS = ("oneshot", "loop", "ramp")
CURVES = ("auto", "power", "linear")
EPS = 1e-12

DEFAULTS = {
    "fade_in_ms": 5.0,
    "fade_out_ms": 40.0,
    "xfade_ms": 400.0,
    "snap_ms": 150.0,
    "curve": "auto",
}
# Полоса поиска «линии»: спектральной линии, которая идёт за оборотами. 800-2500 Гц подходит для тепловоза M44 (линии 926, 1254, 1433 Гц);
# в полосе ниже живут постоянные тона (у M44 это 410 Гц, на оборотах не меняется) и гармоники выхлопа. Меняется `line_band_hz` в листе
LINE_BAND_HZ = (800.0, 2500.0)
PEAKS_BAND_HZ = (100.0, 6000.0)  # полоса для списка пиков top_hz


# ---------------------------------------------------------------- вспомогательное

class Report:
    def __init__(self):
        self.errors = []
        self.warns = []

    def error(self, msg):
        self.errors.append(msg)
        print("ERROR  " + msg)

    def warn(self, msg):
        self.warns.append(msg)
        print("WARN   " + msg)

    @staticmethod
    def info(msg):
        print("INFO   " + msg)


def need_tool(name):
    path = shutil.which(name)
    if not path:
        sys.exit("не найден %s в PATH (нужен ffmpeg: https://ffmpeg.org)" % name)
    return path


def db(x):
    return 20.0 * math.log10(max(float(x), EPS))


def parse_time(v, what="время"):
    """Секунды числом или строка вида 'м:с.д' / 'ч:м:с.д'."""
    if isinstance(v, (int, float)):
        return float(v)
    if isinstance(v, str):
        try:
            parts = [float(p) for p in v.strip().split(":")]
        except ValueError:
            raise ValueError("%s: не число «%s»" % (what, v))
        t = 0.0
        for p in parts:
            t = t * 60.0 + p
        return t
    raise ValueError("%s: ожидалось число или строка, получено %r" % (what, v))


def fmt_time(t):
    return "%d:%06.3f" % (int(t // 60), t - 60 * int(t // 60))


# ---------------------------------------------------------------- чтение и запись звука

def probe(path):
    need_tool("ffprobe")
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "a:0", "-show_entries",
         "stream=sample_rate,channels,codec_name:format=duration", "-of", "json", path],
        capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit("ffprobe не прочитал %s: %s" % (path, out.stderr.strip()))
    d = json.loads(out.stdout)
    st = d["streams"][0]
    return {"sample_rate": int(st["sample_rate"]), "channels": int(st["channels"]),
            "codec": st.get("codec_name", "?"), "duration": float(d["format"].get("duration", 0.0))}


def decode(path, keep_channels=False):
    """Читает файл целиком в float32. Каналы по умолчанию усредняются в моно (сами, не через -ac)."""
    need_tool("ffmpeg")
    info = probe(path)
    ch = info["channels"]
    proc = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-f", "f32le", "-acodec", "pcm_f32le", "-"],
                          capture_output=True)
    if proc.returncode != 0:
        sys.exit("ffmpeg не декодировал %s: %s" % (path, proc.stderr.decode("utf-8", "replace").strip()))
    x = np.frombuffer(proc.stdout, dtype="<f4").astype(np.float32)
    x = x[: (len(x) // ch) * ch].reshape(-1, ch)
    if not keep_channels and ch > 1:
        x = x.mean(axis=1, keepdims=True)
    return x, info["sample_rate"], ch


def to_int16(x):
    return np.clip(np.round(x * 32767.0), -32768, 32767).astype("<i2")


def write_wav(path, x, sr, loop=None):
    """WAV 16 бит. loop=(begin, end) в кадрах, end включительно: пишется блок smpl (Godot читает его как петлю)."""
    if x.ndim == 1:
        x = x[:, None]
    ch = x.shape[1]
    data = to_int16(x).tobytes()
    fmt = struct.pack("<HHIIHH", 1, ch, sr, sr * ch * 2, ch * 2, 16)
    chunks = [b"fmt " + struct.pack("<I", len(fmt)) + fmt]
    if loop is not None:
        smpl = struct.pack("<9I", 0, 0, int(round(1e9 / sr)), 60, 0, 0, 0, 1, 0)
        smpl += struct.pack("<6I", 0, 0, int(loop[0]), int(loop[1]), 0, 0)
        chunks.append(b"smpl" + struct.pack("<I", len(smpl)) + smpl)
    chunks.append(b"data" + struct.pack("<I", len(data)) + data + (b"\0" if len(data) % 2 else b""))
    body = b"WAVE" + b"".join(chunks)
    with open(path, "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", len(body)) + body)


def write_ogg(path, x, sr, quality=6):
    need_tool("ffmpeg")
    with tempfile.TemporaryDirectory() as tmp:
        wav = os.path.join(tmp, "t.wav")
        write_wav(wav, x, sr)
        proc = subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", wav, "-c:a", "libvorbis", "-q:a", str(quality), path],
                              capture_output=True)
        if proc.returncode != 0:
            raise RuntimeError("ffmpeg не записал OGG (нужен libvorbis): " + proc.stderr.decode("utf-8", "replace").strip())


# ---------------------------------------------------------------- спектр

def dominant_hz(x, sr, band=LINE_BAND_HZ, win_s=0.5):
    """Доминирующая линия спектра: средний спектр окон Ханна, пик в полосе, параболическая интерполяция."""
    n = int(win_s * sr)
    if len(x) < 256:
        return 0.0
    n = min(n, len(x))
    w = np.hanning(n).astype(np.float32)
    nfft = 1 << (int(n - 1).bit_length() + 1)  # дополнение нулями вдвое: точнее пик
    acc = None
    count = 0
    hop = max(n // 2, 1)
    for s in range(0, len(x) - n + 1, hop):
        sp = np.abs(np.fft.rfft(x[s:s + n] * w, nfft)) ** 2
        acc = sp if acc is None else acc + sp
        count += 1
    if acc is None:
        return 0.0
    freqs = np.fft.rfftfreq(nfft, 1.0 / sr)
    m = (freqs >= band[0]) & (freqs <= min(band[1], sr / 2 - 1))
    if not m.any():
        return 0.0
    idx = np.flatnonzero(m)
    k = idx[int(np.argmax(acc[idx]))]
    if 0 < k < len(acc) - 1:
        a, b, c = np.log(acc[k - 1] + EPS), np.log(acc[k] + EPS), np.log(acc[k + 1] + EPS)
        den = a - 2 * b + c
        off = 0.5 * (a - c) / den if abs(den) > 1e-12 else 0.0
    else:
        off = 0.0
    return float((k + off) * sr / nfft)


def spectral_peaks(x, sr, n=4, min_sep_hz=40.0, band=PEAKS_BAND_HZ, within_db=12.0, win_s=1.0):
    """До n самых сильных линий среднего спектра: [(Гц, дБ относительно сильнейшей)], линии ближе min_sep_hz друг к другу не повторяются."""
    w_n = min(int(win_s * sr), len(x))
    if w_n < 256:
        return []
    w = np.hanning(w_n).astype(np.float32)
    nfft = 1 << (int(w_n - 1).bit_length() + 1)
    acc = np.zeros(nfft // 2 + 1)
    for s0 in range(0, len(x) - w_n + 1, max(w_n // 2, 1)):
        acc += np.abs(np.fft.rfft(x[s0:s0 + w_n] * w, nfft)) ** 2
    f = np.fft.rfftfreq(nfft, 1.0 / sr)
    idx = np.flatnonzero((f >= band[0]) & (f <= min(band[1], sr / 2 - 1)))
    if len(idx) == 0 or acc[idx].max() <= 0:
        return []
    top = float(acc[idx].max())
    work = acc.copy()
    out = []
    sep = int(min_sep_hz * nfft / sr)
    for _ in range(n):
        k = idx[int(np.argmax(work[idx]))]
        rel = 10.0 * math.log10(work[k] / top)
        if rel < -within_db:
            break
        out.append((round(float(f[k])), round(rel, 1)))
        work[max(k - sep, 0):k + sep + 1] = 0.0
    return out


def rms_dbfs(x):
    if len(x) == 0:
        return -200.0
    return db(math.sqrt(float(np.mean(x.astype(np.float64) ** 2))))


# ---------------------------------------------------------------- анализ ленты

def find_silence(x, sr, min_ms=50.0, thr=1e-4):
    """Цифровая тишина: подряд идущие сэмплы с |x| < thr (−80 dBFS) не короче min_ms."""
    quiet = np.abs(x) < thr
    runs = []
    min_n = int(min_ms * sr / 1000.0)
    d = np.diff(quiet.astype(np.int8), prepend=0, append=0)
    starts = np.flatnonzero(d == 1)
    ends = np.flatnonzero(d == -1)
    for s, e in zip(starts, ends):
        if e - s >= min_n:
            runs.append((s / sr, e / sr))
    return runs


def frame_features(x, sr, hop_s=0.25, win_s=0.5, band=LINE_BAND_HZ):
    hop = int(hop_s * sr)
    n = int(win_s * sr)
    t, lv, hz = [], [], []
    for s in range(0, max(len(x) - n, 0) + 1, hop):
        seg = x[s:s + n]
        t.append(s / sr)
        lv.append(rms_dbfs(seg))
        hz.append(dominant_hz(seg, sr, band=band, win_s=win_s) if lv[-1] > -70 else 0.0)
    return np.array(t), np.array(lv), np.array(hz)


def find_plateaus(t, lv, hz, hop_s, win_s, min_len=2.5, hz_tol=0.02, lv_tol=1.5):
    """Ровные участки: частота держится в пределах hz_tol, уровень в пределах lv_tol дБ от медианы участка."""
    runs = []
    i = 0
    n = len(t)
    while i < n:
        if hz[i] <= 0:
            i += 1
            continue
        j = i + 1
        while j < n and hz[j] > 0:
            med_f = float(np.median(hz[i:j]))
            med_l = float(np.median(lv[i:j]))
            if abs(hz[j] - med_f) / med_f > hz_tol or abs(lv[j] - med_l) > lv_tol:
                break
            j += 1
        start = float(t[i])
        end = float(t[j - 1] + win_s)
        if end - start >= min_len:
            runs.append({"start": start, "end": end, "hz": float(np.median(hz[i:j])),
                         "rms_dbfs": float(np.median(lv[i:j]))})
        i = max(j, i + 1)
    return runs


def find_onsets(x, sr, step_s=0.05, rise_db=8.0, min_gap_s=0.4):
    """Резкие подъёмы уровня (щелчки, начало сигнала): шаг 50 мс, подъём не меньше rise_db над медианой предыдущих 0.2 с."""
    step = int(step_s * sr)
    frames = len(x) // step
    if frames < 6:
        return []
    env = np.array([rms_dbfs(x[k * step:(k + 1) * step]) for k in range(frames)])
    out = []
    last = -1e9
    for k in range(4, frames):
        prev = float(np.median(env[k - 4:k]))
        if env[k] - prev >= rise_db and env[k] > -50 and k * step_s - last >= min_gap_s:
            out.append((k * step_s, float(env[k])))
            last = k * step_s
    return out


def make_spectrogram(path, png, max_hz=6000.0, width=2400, height=720):
    """PNG: время по горизонтали, частота 0..max_hz по вертикали (лента сводится в моно и передискретизируется)."""
    need_tool("ffmpeg")
    proc = subprocess.run(
        ["ffmpeg", "-v", "error", "-y", "-i", path, "-ac", "1", "-lavfi",
         "aresample=%d,showspectrumpic=s=%dx%d:legend=1:scale=log:fscale=lin:color=intensity" % (int(max_hz * 2), width, height), png],
        capture_output=True)
    if proc.returncode != 0:
        return proc.stderr.decode("utf-8", "replace").strip()
    return None


def cmd_analyze(args):
    rep = Report()
    x, sr, ch = decode(args.audio)
    x = x[:, 0]
    dur = len(x) / sr
    peak = float(np.max(np.abs(x))) if len(x) else 0.0
    over = int(np.sum(np.abs(x) > 0.99))
    print("%s: %.2f с, %d Гц, каналов в файле %d, пик %.1f dBFS, сэмплов выше 0.99: %d"
          % (args.audio, dur, sr, ch, db(peak), over))
    if over:
        rep.warn("пик у 0 dBFS (%d сэмплов): при нарезке общее усиление опустит уровень; клиппинг в исходнике останется" % over)

    sil = find_silence(x, sr, args.silence_ms)
    print("\nЦифровая тишина (не короче %g мс): %d" % (args.silence_ms, len(sil)))
    for a, b in sil:
        print("   %s .. %s  (%.2f с)" % (fmt_time(a), fmt_time(b), b - a))
    if not sil:
        print("   нет: лента сплошная, границы придётся ставить по спектрограмме и на слух")

    on = find_onsets(x, sr)
    print("\nРезкие подъёмы уровня: %d" % len(on))
    for t0, lvl in on:
        print("   %s  %.1f dBFS" % (fmt_time(t0), lvl))

    hop_s, win_s = 0.25, 0.5
    band = (args.band[0], args.band[1])
    t, lv, hz = frame_features(x, sr, hop_s, win_s, band)
    runs = find_plateaus(t, lv, hz, hop_s, win_s, min_len=args.min_plateau)
    print("\nРовные участки (линия %.0f-%.0f Гц ±2%%, уровень ±1.5 дБ, не короче %g с): %d" % (band[0], band[1], args.min_plateau, len(runs)))
    for r in runs:
        print("   %s .. %s  (%.1f с)  линия %.0f Гц  %.1f dBFS" %
              (fmt_time(r["start"]), fmt_time(r["end"]), r["end"] - r["start"], r["hz"], r["rms_dbfs"]))
    if not runs:
        rep.warn("ровных участков нет: для петель нужен стабильный звук не короче %g с" % args.min_plateau)

    if args.spectrogram:
        err = make_spectrogram(args.audio, args.spectrogram, args.spec_max_hz)
        if err:
            rep.warn("спектрограмма не создана: " + err)
        else:
            print("\nСпектрограмма: %s (по горизонтали время, по вертикали частота, шкала частоты линейная)" % args.spectrogram)

    if args.out:
        if os.path.exists(args.out) and not args.force:
            rep.error("%s уже есть (перезапись только с --force)" % args.out)
        else:
            sheet_dir = os.path.dirname(os.path.abspath(args.out))
            stem = os.path.basename(args.audio).rsplit(".", 1)[0].lower()
            sid = re.sub(r"[^a-z0-9_]+", "_", stem).strip("_") or "sheet"
            if not sid[0].isalpha():
                sid = "s_" + sid
            regions = []
            # границы блоков из тишины и ровные участки; имена временные, их задаёт человек
            edges = [0.0] + [m for a, b in sil for m in (a, b)] + [dur]
            for k in range(0, len(edges) - 1, 2):
                a, b = edges[k], edges[k + 1]
                if b - a >= 0.1:
                    regions.append({"id": "block_%02d" % (len(regions) + 1), "kind": "oneshot",
                                    "start": round(a, 3), "end": round(b, 3), "tags": [], "note": "блок между паузами, проверить на слух"})
            for k, r in enumerate(runs):
                regions.append({"id": "loop_%02d" % (k + 1), "kind": "loop",
                                "start": round(r["start"], 3), "end": round(r["end"], 3), "tags": ["engine"],
                                "note": "кандидат: линия %.0f Гц, %.1f dBFS; проверить на слух" % (r["hz"], r["rms_dbfs"])})
            draft = {"id": sid, "source": _rel(os.path.abspath(args.audio), sheet_dir),
                     "note": "ЗАГОТОВКА: id, kind и границы проверить на слух и по спектрограмме, имена заменить",
                     "reference": "", "defaults": {}, "regions": regions}
            with open(args.out, "w", encoding="utf-8") as f:
                json.dump(draft, f, ensure_ascii=False, indent=2)
                f.write("\n")
            print("\nЗаготовка листа меток: %s (%d регионов)" % (args.out, len(regions)))
    return 1 if rep.errors else 0


# ---------------------------------------------------------------- лист меток

def _rel(path, start):
    """Путь от start со слэшами; на другом диске (Windows) остаётся абсолютным."""
    try:
        return os.path.relpath(path, start).replace("\\", "/")
    except ValueError:
        return path.replace("\\", "/")


def load_sheet(path, rep):
    try:
        with open(path, encoding="utf-8") as f:
            sh = json.load(f)
    except (OSError, ValueError) as e:
        sys.exit("лист %s не прочитан: %s" % (path, e))
    for key in ("id", "source", "regions"):
        if key not in sh:
            sys.exit("в листе нет поля «%s»" % key)
    if not ID_RE.match(str(sh["id"])):
        rep.error("id листа «%s»: только a-z, 0-9, _ , начинается с буквы" % sh["id"])
    return sh


def check_regions(sh, dur, rep):
    """Проверка листа. Возвращает список регионов с числами (секунды) и применёнными умолчаниями."""
    defaults = dict(DEFAULTS)
    defaults.update(sh.get("defaults", {}))
    seen = set()
    out = []
    for i, r in enumerate(sh["regions"]):
        rid = str(r.get("id", ""))
        where = "region[%d] «%s»" % (i, rid)
        if not ID_RE.match(rid):
            rep.error("%s: id только a-z, 0-9, _ , начинается с буквы" % where)
            continue
        if rid in seen:
            rep.error("%s: повторяющийся id" % where)
            continue
        seen.add(rid)
        kind = r.get("kind", "oneshot")
        if kind not in KINDS:
            rep.error("%s: kind «%s», допустимо %s" % (where, kind, ", ".join(KINDS)))
            continue
        try:
            a = parse_time(r["start"], where + " start")
            b = parse_time(r["end"], where + " end")
        except (KeyError, ValueError) as e:
            rep.error("%s: %s" % (where, e))
            continue
        if not (0.0 <= a < b):
            rep.error("%s: нужно 0 <= start < end (%.3f, %.3f)" % (where, a, b))
            continue
        if b > dur + 0.05:
            rep.error("%s: end %.3f за концом файла (%.3f)" % (where, b, dur))
            continue
        b = min(b, dur)
        cfg = dict(defaults)
        for k in ("fade_in_ms", "fade_out_ms", "xfade_ms", "snap_ms", "curve", "gain_db"):
            if k in r:
                cfg[k] = r[k]
        band = r.get("band_hz", sh.get("line_band_hz", list(LINE_BAND_HZ)))
        if not (isinstance(band, list) and len(band) == 2 and 0 < band[0] < band[1]):
            rep.error("%s: band_hz / line_band_hz должны быть [от, до] в Гц" % where)
            continue
        cfg["band_hz"] = (float(band[0]), float(band[1]))
        if cfg["curve"] not in CURVES:
            rep.error("%s: curve «%s», допустимо %s" % (where, cfg["curve"], ", ".join(CURVES)))
            continue
        if b - a < 0.05:
            rep.warn("%s: короче 50 мс" % where)
        if kind == "loop" and b - a < 2.0:
            rep.warn("%s: петля %.1f с: слишком коротка, повтор будет слышен (нужно 5-10 с и больше)" % (where, b - a))
        out.append({"id": rid, "kind": kind, "start": a, "end": b, "tags": list(r.get("tags", [])),
                    "note": r.get("note", ""), "cfg": cfg})
    ref = sh.get("reference", "")
    if ref and ref not in seen:
        rep.error("reference «%s»: такого региона нет" % ref)
    return out


# ---------------------------------------------------------------- нарезка

def _fade_weights(n, curve, rho):
    """Веса кроссфейда (на входе, на выходе). linear: u и 1-u (для совпадающих по фазе сигналов).
    power: sin и cos (для несвязанных сигналов, rho=0). auto: sin и cos, нормированные так, чтобы мощность суммы
    оставалась постоянной при измеренной корреляции rho окон (rho=0 даёт power, rho=1 даёт linear)."""
    u = (np.arange(n, dtype=np.float64) + 0.5) / n
    if curve == "linear":
        return u, 1.0 - u
    w_in, w_out = np.sin(0.5 * math.pi * u), np.cos(0.5 * math.pi * u)
    if curve == "auto":
        r = min(max(rho, 0.0), 1.0)
        norm = np.sqrt(w_in ** 2 + w_out ** 2 + 2.0 * r * w_in * w_out)
        w_in, w_out = w_in / norm, w_out / norm
    return w_in, w_out


def apply_edges(y, sr, fade_in_ms, fade_out_ms):
    y = y.copy()
    n_in = min(int(fade_in_ms * sr / 1000.0), len(y) // 2)
    n_out = min(int(fade_out_ms * sr / 1000.0), len(y) // 2)
    if n_in > 0:
        y[:n_in] *= (0.5 - 0.5 * np.cos(np.pi * (np.arange(n_in) + 0.5) / n_in)).astype(np.float32)[:, None]
    if n_out > 0:
        y[-n_out:] *= (0.5 + 0.5 * np.cos(np.pi * (np.arange(n_out) + 0.5) / n_out)).astype(np.float32)[:, None]
    return y


def _ncc_search(x, a, b0, xf, snap):
    """Подбор конца петли b в [b0-snap, b0] (только внутрь региона: за его концом может начинаться другой звук): максимум нормированной корреляции окна x[b-xf:b] с головой x[a:a+xf].
    Окно целиком внутри файла, длина петли после подбора остаётся не меньше 3*xf. Возвращает (b, ncc)."""
    head = x[a:a + xf].astype(np.float64)
    hn = float(np.sqrt(np.dot(head, head))) + EPS
    lo = max(b0 - snap, a + 3 * xf, xf)
    hi = min(b0, len(x))
    if hi < lo:
        return b0, 0.0
    seg = x[lo - xf:hi].astype(np.float64)
    n = len(seg)
    nfft = 1 << int(n + xf).bit_length()
    corr = np.fft.irfft(np.fft.rfft(seg, nfft) * np.conj(np.fft.rfft(head, nfft)), nfft)[: n - xf + 1]
    c2 = np.concatenate(([0.0], np.cumsum(seg * seg)))
    wn = np.sqrt(np.maximum(c2[xf:] - c2[:-xf], 0.0)) + EPS
    ncc = corr / (wn * hn)
    k = int(np.argmax(ncc))
    return lo + k, float(ncc[k])


def make_loop(x, sr, a, b, cfg):
    """Петля из x[a:b]. Возвращает (звук, инфо). Длина результата: (b' - a) - xf, где b' конец после подбора."""
    xf = int(cfg["xfade_ms"] * sr / 1000.0)
    snap = int(cfg["snap_ms"] * sr / 1000.0)
    xf = max(min(xf, (b - a) // 3), 16)
    mono = x[:, 0]
    b2, ncc = (b, 0.0)
    if snap > 0:
        b2, ncc = _ncc_search(mono, a, b, xf, snap)
    else:
        head = mono[a:a + xf].astype(np.float64)
        tail = mono[b - xf:b].astype(np.float64)
        ncc = float(np.dot(head, tail) / ((np.linalg.norm(head) * np.linalg.norm(tail)) + EPS))
    curve = cfg["curve"]
    w_in, w_out = _fade_weights(xf, curve, ncc)
    w_in = w_in.astype(np.float32)[:, None]
    w_out = w_out.astype(np.float32)[:, None]
    blend = x[b2 - xf:b2] * w_out + x[a:a + xf] * w_in
    y = np.concatenate([blend, x[a + xf:b2 - xf]], axis=0)
    inner = y[xf:]
    # провал или всплеск громкости в зоне кроссфейда относительно остального
    dip = rms_dbfs(y[:xf]) - rms_dbfs(inner) if len(inner) else 0.0
    info = {"xfade_ms": round(xf * 1000.0 / sr, 1), "curve": curve,
            "ncc": round(ncc, 3), "end_shift_ms": round((b2 - b) * 1000.0 / sr, 1),
            "xfade_level_db": round(dip, 2)}
    return y, info


def cmd_slice(args):
    rep = Report()
    sheet_path = os.path.abspath(args.sheet)
    sheet_dir = os.path.dirname(sheet_path)
    sh = load_sheet(sheet_path, rep)
    src = os.path.normpath(os.path.join(sheet_dir, sh["source"]))
    if not os.path.isfile(src):
        sys.exit("исходник не найден: %s" % src)
    x, sr, ch = decode(src, keep_channels=args.stereo)
    dur = len(x) / sr
    regions = check_regions(sh, dur, rep)
    # общее усиление считается по ВСЕМ регионам листа, чтобы запуск с --only давал те же уровни, что полный
    src_peak = 0.0
    for g in regions:
        seg = x[int(round(g["start"] * sr)):min(int(round(g["end"] * sr)), len(x))]
        if len(seg):
            src_peak = max(src_peak, float(np.max(np.abs(seg))))
    if args.only:
        missing = [r for r in args.only if r not in {g["id"] for g in regions}]
        for m in missing:
            rep.error("--only: региона «%s» нет в листе" % m)
        regions = [g for g in regions if g["id"] in args.only]
    if rep.errors:
        return 1

    print("\n%-16s %-8s %9s %9s %7s" % ("id", "kind", "start", "end", "длина"))
    for g in regions:
        print("%-16s %-8s %9s %9s %6.2fс" % (g["id"], g["kind"], fmt_time(g["start"]), fmt_time(g["end"]), g["end"] - g["start"]))
    if args.dry_run:
        print("\n--dry-run: лист проверен, файлы не записаны (регионов: %d, ошибок нет)" % len(regions))
        return 0

    # 1. клипы без усиления
    clips = []
    for g in regions:
        a = int(round(g["start"] * sr))
        b = min(int(round(g["end"] * sr)), len(x))
        cfg = g["cfg"]
        if g["kind"] == "loop":
            y, loop_info = make_loop(x, sr, a, b, cfg)
            if abs(loop_info["xfade_level_db"]) > 1.0:
                rep.warn("%s: в зоне кроссфейда уровень отличается на %.1f дБ (ncc %.2f): сдвинуть границы или уменьшить xfade_ms"
                         % (g["id"], loop_info["xfade_level_db"], loop_info["ncc"]))
            if loop_info["ncc"] < 0.2:
                rep.warn("%s: корреляция шва %.2f: начало и конец плохо совпадают по фазе, кроссфейд смешивает несвязанные сигналы (без провала громкости); проверить на слух повтор и биения"
                         % (g["id"], loop_info["ncc"]))
        else:
            y = apply_edges(x[a:b], sr, cfg["fade_in_ms"], cfg["fade_out_ms"])
            loop_info = None
        clips.append((g, y, loop_info, a, b))

    # 2. общее усиление: самый громкий пик источника встаёт на peak_dbfs
    peak = src_peak
    gain_db = 0.0 if args.no_normalize else args.peak_dbfs - db(peak)
    print("\nОбщее усиление %+.1f дБ (пик источника до: %.1f dBFS, после: %.1f dBFS)" % (gain_db, db(peak), db(peak) + gain_db))
    g_lin = 10.0 ** (gain_db / 20.0)

    out_dir = args.out or os.path.join(sheet_dir, sh["id"])
    os.makedirs(out_dir, exist_ok=True)
    ext = "ogg" if args.format == "ogg" else "wav"
    ref_hz = None
    entries = []
    for g, y, loop_info, a, b in clips:
        y = y * np.float32(g_lin * 10.0 ** (float(g["cfg"].get("gain_db", 0.0)) / 20.0))
        pk = float(np.max(np.abs(y)))
        if pk > 1.0:
            rep.warn("%s: после усиления пик %.1f dBFS выше 0: будет срезан; уменьшить gain_db региона или взять --peak-dbfs ниже" % (g["id"], db(pk)))
        elif pk > 10.0 ** (-0.5 / 20.0):
            rep.warn("%s: пик %.1f dBFS у предела" % (g["id"], db(pk)))
        fname = "%s_%s.%s" % (sh["id"], g["id"], ext)
        loop = None
        if loop_info is not None:
            loop = (0, len(y) - 1)
        path = os.path.join(out_dir, fname)
        if ext == "wav":
            write_wav(path, y, sr, loop=loop)
        else:
            try:
                write_ogg(path, y, sr)
            except RuntimeError as e:
                rep.error(str(e))
                return 1
        mono = y[:, 0] if y.ndim == 2 else y
        entry = {"id": g["id"], "file": fname, "kind": g["kind"], "tags": g["tags"],
                 "src_start": round(g["start"], 3), "src_end": round(g["end"], 3),
                 "duration": round(len(y) / sr, 3), "samples": int(len(y)),
                 "rms_dbfs": round(rms_dbfs(mono), 1), "peak_dbfs": round(db(pk), 1),
                 "line_band_hz": list(g["cfg"]["band_hz"]),
                 "dominant_hz": round(dominant_hz(mono, sr, band=g["cfg"]["band_hz"]), 1),
                 "top_hz": [list(p) for p in spectral_peaks(mono, sr)]}
        if g["kind"] == "ramp":
            seg = int(min(0.5, len(mono) / sr / 3) * sr)
            entry["hz_start"] = round(dominant_hz(mono[:seg], sr, band=g["cfg"]["band_hz"], win_s=0.25), 1)
            entry["hz_end"] = round(dominant_hz(mono[-seg:], sr, band=g["cfg"]["band_hz"], win_s=0.25), 1)
        if loop_info is not None:
            entry["loop"] = dict(loop_info, begin=0, end=len(y) - 1,
                                 in_file=(ext == "wav"))
        if g["note"]:
            entry["note"] = g["note"]
        if g["id"] == sh.get("reference"):
            ref_hz = entry["dominant_hz"]
        entries.append(entry)
        extra = ""
        if loop_info is not None:
            extra = "  петля: шов ncc %.2f, %s, сдвиг конца %+.0f мс, зона %+.1f дБ" % (
                loop_info["ncc"], loop_info["curve"], loop_info["end_shift_ms"], loop_info["xfade_level_db"])
        print("OK     %-26s %6.2f с  %6.1f dBFS RMS  линия %6.0f Гц%s" % (fname, entry["duration"], entry["rms_dbfs"], entry["dominant_hz"], extra))

    if ref_hz:
        for e in entries:
            if e["dominant_hz"] > 0:
                e["ratio_to_reference"] = round(e["dominant_hz"] / ref_hz, 3)

    manifest = {"sheet": os.path.basename(sheet_path), "source": _rel(src, out_dir),
                "sample_rate": sr, "channels": ch if args.stereo else 1, "format": ext,
                "gain_db": round(gain_db, 2), "peak_dbfs": args.peak_dbfs if not args.no_normalize else None,
                "reference": sh.get("reference", ""), "reference_hz": ref_hz,
                "warnings": rep.warns, "regions": entries}
    with open(os.path.join(out_dir, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print("\nЗаписано: %d файлов и manifest.json в %s (предупреждений: %d)" % (len(entries), out_dir, len(rep.warns)))
    return 1 if rep.errors else 0


def main(argv=None):
    # на Windows вывод в файл или через пайп может идти в 8-битной кодировке: символы вне её заменяются, а не роняют скрипт
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(errors="replace")
    ap = argparse.ArgumentParser(description="Подготовка звуковых файлов из ленты-образца (ATTN_26 §26.6).")
    sub = ap.add_subparsers(dest="cmd", required=True)

    an = sub.add_parser("analyze", help="разбор ленты: тишина, всплески, ровные участки, заготовка листа меток")
    an.add_argument("audio")
    an.add_argument("--out", help="записать заготовку листа меток (*.sheet.json)")
    an.add_argument("--force", action="store_true", help="перезаписать --out")
    an.add_argument("--spectrogram", metavar="PNG", help="сохранить спектрограмму для разметки на глаз")
    an.add_argument("--band", type=float, nargs=2, metavar=("LO", "HI"), default=LINE_BAND_HZ,
                    help="полоса поиска линии оборотов, Гц (по умолчанию %g %g)" % LINE_BAND_HZ)
    an.add_argument("--spec-max-hz", type=float, default=6000.0, help="верхняя частота спектрограммы, Гц (по умолчанию 6000)")
    an.add_argument("--min-plateau", type=float, default=2.5, help="минимальная длина ровного участка, с (по умолчанию 2.5)")
    an.add_argument("--silence-ms", type=float, default=50.0, help="минимальная цифровая тишина, мс (по умолчанию 50)")
    an.set_defaults(fn=cmd_analyze)

    sl = sub.add_parser("slice", help="нарезка по листу меток")
    sl.add_argument("sheet")
    sl.add_argument("--out", help="папка результата (по умолчанию <папка листа>/<id листа>)")
    sl.add_argument("--format", choices=("wav", "ogg"), default="wav")
    sl.add_argument("--only", nargs="+", metavar="ID", help="только эти регионы")
    sl.add_argument("--peak-dbfs", type=float, default=-3.0, help="куда ставить самый громкий пик (по умолчанию -3)")
    sl.add_argument("--no-normalize", action="store_true", help="не менять усиление")
    sl.add_argument("--stereo", action="store_true", help="сохранить каналы исходника (по умолчанию моно)")
    sl.add_argument("--dry-run", action="store_true", help="только проверить лист")
    sl.set_defaults(fn=cmd_slice)

    args = ap.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
