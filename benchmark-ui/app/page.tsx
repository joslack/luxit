"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";

const API = process.env.NEXT_PUBLIC_STTBENCH_API ?? "http://127.0.0.1:8765";

type CorpusCase = {
  id: string;
  category: string;
  text: string;
  keywords: string[];
  note: string;
};

type Backend = {
  id: string;
  name: string;
  family: string;
  description: string;
  model: string;
  available: boolean;
  unavailable_reasons: string[];
  capabilities: {
    prompt: boolean;
    persistent: boolean;
    streaming: boolean;
    languages: string[];
  };
  setup: string;
};

type Recording = {
  id: string;
  case_id: string;
  reference: string;
  created_at: string;
};

type Result = {
  result_id: string;
  recording_id: string;
  backend_id: string;
  backend_name: string;
  family: string;
  text: string;
  error?: string;
  wall_ms: number;
  backend_ms?: number;
  load_ms?: number;
  audio_seconds: number;
  realtime_factor?: number;
  warm: boolean;
  scores?: {
    wer: number;
    word_accuracy: number;
    character_accuracy: number;
    keyword_recall?: number;
    exact_normalized: boolean;
  };
};

type RatingValue = "useful" | "needs_edit" | "wrong";

type ManualRating = {
  result_id: string;
  recording_id: string;
  backend_id: string;
  rating: RatingValue;
  corrected_text?: string;
  updated_at: string;
  created_at: string;
};

type ResultsResponse = {
  results: unknown[];
};

type CorpusImportMode = "json" | "lines";

type LeaderboardRow = {
  backend_id: string;
  backend_name: string;
  family: string;
  warm: boolean;
  count: number;
  error_count: number;
  word_accuracy_mean: number | null;
  keyword_recall_mean: number | null;
  latency_mean_ms: number | null;
  realtime_factor_mean: number | null;
  manual_rating_counts: Record<RatingValue, number>;
};

type Job = {
  id: string;
  status: "queued" | "running" | "complete" | "failed";
  results: Result[];
  error?: string;
};

const RATING_OPTIONS: ReadonlyArray<{ value: RatingValue; label: string }> = [
  { value: "useful", label: "Useful" },
  { value: "needs_edit", label: "Needs edit" },
  { value: "wrong", label: "Wrong" },
] as const;

function isRatingValue(value: unknown): value is RatingValue {
  return value === "useful" || value === "needs_edit" || value === "wrong";
}

function normalizeRatings(value: unknown): Record<string, ManualRating> {
  if (!value || !("ratings" in (value as Record<string, unknown>))) {
    return {};
  }
  const data = (value as { ratings: unknown }).ratings;
  if (!data || typeof data !== "object") return {};
  if (Array.isArray(data)) {
    const grouped: Record<string, ManualRating> = {};
    for (const item of data) {
      if (!item || typeof item !== "object") continue;
      const entry = item as Record<string, unknown>;
      const id = entry.result_id;
      const rating = entry.rating;
      if (typeof id !== "string" || !isRatingValue(rating)) continue;
      const corrected = typeof entry.corrected_text === "string" ? entry.corrected_text : undefined;
      if (typeof entry.created_at !== "string" || typeof entry.updated_at !== "string") continue;
      grouped[id] = {
        result_id: id,
        recording_id: typeof entry.recording_id === "string" ? entry.recording_id : "",
        backend_id: typeof entry.backend_id === "string" ? entry.backend_id : "",
        rating,
        corrected_text: corrected,
        created_at: entry.created_at,
        updated_at: entry.updated_at,
      };
    }
    return grouped;
  }
  const grouped: Record<string, ManualRating> = {};
  for (const [key, value] of Object.entries(data)) {
    if (!value || typeof value !== "object") continue;
    const entry = value as Record<string, unknown>;
    if (typeof key !== "string") continue;
    const rating = entry.rating;
    if (!isRatingValue(rating)) continue;
    const created = entry.created_at;
    const updated = entry.updated_at;
    if (typeof created !== "string" || typeof updated !== "string") continue;
    const corrected = typeof entry.corrected_text === "string" ? entry.corrected_text : undefined;
    grouped[key] = {
      result_id: key,
      recording_id: typeof entry.recording_id === "string" ? entry.recording_id : "",
      backend_id: typeof entry.backend_id === "string" ? entry.backend_id : "",
      rating,
      corrected_text: corrected,
      created_at: created,
      updated_at: updated,
    };
  }
  return grouped;
}

function normalizeSummary(value: unknown): LeaderboardRow[] {
  if (!value || typeof value !== "object") return [];
  const payload = value as Record<string, unknown>;
  const raw = payload.summary;
  if (!Array.isArray(raw)) return [];
  const rows: LeaderboardRow[] = [];
  for (const item of raw) {
    if (!item || typeof item !== "object") continue;
    const entry = item as Record<string, unknown>;
    const ratingRaw = entry.manual_rating_counts;
    const counts =
      ratingRaw && typeof ratingRaw === "object"
        ? {
            useful: Number((ratingRaw as Record<string, unknown>).useful || 0),
            needs_edit: Number((ratingRaw as Record<string, unknown>).needs_edit || 0),
            wrong: Number((ratingRaw as Record<string, unknown>).wrong || 0),
          }
        : { useful: 0, needs_edit: 0, wrong: 0 };
    rows.push({
      backend_id: String(entry.backend_id || ""),
      backend_name: String(entry.backend_name || String(entry.backend_id || "")),
      family: String(entry.family || ""),
      warm: entry.warm === true,
      count: Number(entry.count || 0),
      error_count: Number(entry.error_count || 0),
      word_accuracy_mean:
        typeof entry.word_accuracy_mean === "number" ? entry.word_accuracy_mean : null,
      keyword_recall_mean:
        typeof entry.keyword_recall_mean === "number" ? entry.keyword_recall_mean : null,
      latency_mean_ms: typeof entry.latency_mean_ms === "number" ? entry.latency_mean_ms : null,
      realtime_factor_mean:
        typeof entry.realtime_factor_mean === "number" ? entry.realtime_factor_mean : null,
      manual_rating_counts: counts,
    });
  }
  return rows;
}

function normalizeResults(value: unknown): Result[] {
  if (!value || typeof value !== "object") return [];
  const payload = value as ResultsResponse;
  if (!Array.isArray(payload.results)) return [];

  const output: Result[] = [];
  for (const item of payload.results) {
    if (!item || typeof item !== "object") continue;
    const entry = item as Record<string, unknown>;
    const resultId = typeof entry.result_id === "string" ? entry.result_id : "";
    if (!resultId) continue;
    const scoresValue = entry.scores;
    let scores: Result["scores"] | undefined;
    if (scoresValue && typeof scoresValue === "object") {
      const record = scoresValue as Record<string, unknown>;
      const wer = record.wer;
      const wordAccuracy = record.word_accuracy;
      const characterAccuracy = record.character_accuracy;
      if (
        typeof wer === "number" &&
        typeof wordAccuracy === "number" &&
        typeof characterAccuracy === "number"
      ) {
        scores = {
          wer,
          word_accuracy: wordAccuracy,
          character_accuracy: characterAccuracy,
          keyword_recall:
            typeof record.keyword_recall === "number" ? record.keyword_recall : undefined,
          exact_normalized:
            typeof record.exact_normalized === "boolean" ? record.exact_normalized : false,
        };
      }
    }

    output.push({
      result_id: resultId,
      recording_id: typeof entry.recording_id === "string" ? entry.recording_id : "",
      backend_id: typeof entry.backend_id === "string" ? entry.backend_id : "",
      backend_name: typeof entry.backend_name === "string" ? entry.backend_name : "",
      family: typeof entry.family === "string" ? entry.family : "",
      text: typeof entry.text === "string" ? entry.text : "",
      error: typeof entry.error === "string" ? entry.error : undefined,
      wall_ms: typeof entry.wall_ms === "number" ? entry.wall_ms : 0,
      backend_ms: typeof entry.backend_ms === "number" ? entry.backend_ms : undefined,
      load_ms: typeof entry.load_ms === "number" ? entry.load_ms : undefined,
      audio_seconds: typeof entry.audio_seconds === "number" ? entry.audio_seconds : 0,
      realtime_factor:
        typeof entry.realtime_factor === "number" ? entry.realtime_factor : undefined,
      warm: entry.warm === true,
      scores: scores,
    });
  }
  return output;
}

function percent(value: number | null | undefined) {
  if (value == null) return "—";
  return `${(value * 100).toFixed(1)}%`;
}

function encodeWav(chunks: Float32Array[], inputRate: number): Blob {
  const total = chunks.reduce((sum, chunk) => sum + chunk.length, 0);
  const input = new Float32Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    input.set(chunk, offset);
    offset += chunk.length;
  }

  const outputRate = 16000;
  const ratio = inputRate / outputRate;
  const outputLength = Math.max(1, Math.round(input.length / ratio));
  const output = new Float32Array(outputLength);
  for (let index = 0; index < outputLength; index += 1) {
    const start = Math.floor(index * ratio);
    const end = Math.min(input.length, Math.floor((index + 1) * ratio));
    let sum = 0;
    for (let source = start; source < end; source += 1) sum += input[source];
    output[index] = sum / Math.max(1, end - start);
  }

  const buffer = new ArrayBuffer(44 + output.length * 2);
  const view = new DataView(buffer);
  const write = (at: number, value: string) => {
    for (let index = 0; index < value.length; index += 1) {
      view.setUint8(at + index, value.charCodeAt(index));
    }
  };
  write(0, "RIFF");
  view.setUint32(4, 36 + output.length * 2, true);
  write(8, "WAVE");
  write(12, "fmt ");
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);
  view.setUint16(22, 1, true);
  view.setUint32(24, outputRate, true);
  view.setUint32(28, outputRate * 2, true);
  view.setUint16(32, 2, true);
  view.setUint16(34, 16, true);
  write(36, "data");
  view.setUint32(40, output.length * 2, true);
  output.forEach((sample, index) => {
    const clamped = Math.max(-1, Math.min(1, sample));
    view.setInt16(44 + index * 2, clamped < 0 ? clamped * 32768 : clamped * 32767, true);
  });
  return new Blob([buffer], { type: "audio/wav" });
}

function milliseconds(value?: number) {
  if (value == null) return "—";
  if (value < 1000) return `${Math.round(value)} ms`;
  return `${(value / 1000).toFixed(2)} s`;
}

export default function Home() {
  const [connected, setConnected] = useState(false);
  const [cases, setCases] = useState<CorpusCase[]>([]);
  const [backends, setBackends] = useState<Backend[]>([]);
  const [recordings, setRecordings] = useState<Recording[]>([]);
  const [caseIndex, setCaseIndex] = useState(0);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [isRecording, setIsRecording] = useState(false);
  const [recordingSeconds, setRecordingSeconds] = useState(0);
  const [job, setJob] = useState<Job | null>(null);
  const [error, setError] = useState("");
  const [warmups, setWarmups] = useState(1);
  const [repetitions, setRepetitions] = useState(1);
  const [prompt, setPrompt] = useState("");
  const [ratings, setRatings] = useState<Record<string, ManualRating>>({});
  const [ratingDrafts, setRatingDrafts] = useState<Record<string, string>>({});
  const [storedResults, setStoredResults] = useState<Result[]>([]);
  const [familyFilter, setFamilyFilter] = useState("all");
  const [readyOnly, setReadyOnly] = useState(true);
  const [summary, setSummary] = useState<LeaderboardRow[]>([]);
  const [corpusImportMode, setCorpusImportMode] = useState<CorpusImportMode>("lines");
  const [corpusText, setCorpusText] = useState("");
  const [importingCorpus, setImportingCorpus] = useState(false);

  const audioContext = useRef<AudioContext | null>(null);
  const mediaStream = useRef<MediaStream | null>(null);
  const processor = useRef<ScriptProcessorNode | null>(null);
  const audioChunks = useRef<Float32Array[]>([]);
  const startedAt = useRef(0);
  const timer = useRef<ReturnType<typeof setInterval> | null>(null);

  const activeCase = cases[caseIndex];
  const activeRecording = useMemo(
    () => recordings.find((recording) => recording.case_id === activeCase?.id),
    [activeCase, recordings],
  );
  const completedCases = useMemo(
    () => new Set(recordings.map((recording) => recording.case_id)).size,
    [recordings],
  );
  const familyOptions = useMemo(
    () => [...new Set(backends.map((backend) => backend.family))].sort(),
    [backends],
  );
  const filteredBackends = useMemo(() => {
    return backends.filter((backend) => {
      if (readyOnly && !backend.available) return false;
      if (familyFilter !== "all" && backend.family !== familyFilter) return false;
      return true;
    });
  }, [backends, familyFilter, readyOnly]);
  const runnableBackendIds = useMemo(
    () => new Set(backends.filter((backend) => backend.available).map((backend) => backend.id)),
    [backends],
  );
  const selectedBackendIds = useMemo(
    () => [...selected].filter((backendId) => runnableBackendIds.has(backendId)),
    [selected, runnableBackendIds],
  );

  const refresh = useCallback(async () => {
    try {
      const [
        statusResponse,
        corpusResponse,
        backendResponse,
        recordingResponse,
        ratingsResponse,
        summaryResponse,
      ] =
        await Promise.all([
          fetch(`${API}/api/status`),
          fetch(`${API}/api/corpus`),
          fetch(`${API}/api/backends`),
          fetch(`${API}/api/recordings`),
          fetch(`${API}/api/ratings`),
          fetch(`${API}/api/summary`),
        ]);
      if (!statusResponse.ok) throw new Error("The local benchmark service is not responding.");
      const corpus = await corpusResponse.json();
      const backendPayload = await backendResponse.json();
      const recordingPayload = await recordingResponse.json();
      const ratingsPayload = ratingsResponse.ok ? await ratingsResponse.json() : { ratings: {} };
      const summaryPayload = summaryResponse.ok ? await summaryResponse.json() : { summary: [] };
      setCases(corpus.cases);
      setBackends(backendPayload.backends);
      setRecordings(recordingPayload.recordings);
      setRatings(normalizeRatings(ratingsPayload));
      setSummary(normalizeSummary(summaryPayload));
      setSelected((current) => {
        const next = new Set(
          [...current].filter((backendId) =>
            backendPayload.backends.some((backend: Backend) => backend.id === backendId && backend.available),
          ),
        );
        if (next.size) return next;
        return new Set(
          backendPayload.backends
            .filter((backend: Backend) => backend.available)
            .map((backend: Backend) => backend.id),
        );
      });
      setConnected(true);
      setError("");
    } catch (reason) {
      setConnected(false);
      setError(reason instanceof Error ? reason.message : "Could not connect.");
    }
  }, []);

  useEffect(() => {
    refresh();
  }, [refresh]);

  useEffect(() => {
    if (corpusText || !cases.length) return;
    if (corpusImportMode === "json") {
      setCorpusText(JSON.stringify(cases, null, 2));
    } else {
      setCorpusText(cases.map((item) => item.text).join("\n"));
    }
  }, [cases, corpusImportMode, corpusText]);

  useEffect(() => {
    if (!job || (job.status !== "queued" && job.status !== "running")) return;
    const poller = setInterval(async () => {
      const response = await fetch(`${API}/api/jobs/${job.id}`);
      if (response.ok) setJob(await response.json());
    }, 650);
    return () => clearInterval(poller);
  }, [job]);

  useEffect(() => {
    if (!activeRecording) {
      setStoredResults([]);
      return;
    }
    let cancelled = false;
    void (async () => {
      const response = await fetch(
        `${API}/api/results?recording_id=${encodeURIComponent(activeRecording.id)}`,
      );
      if (!response.ok) {
        if (!cancelled) setStoredResults([]);
        return;
      }
      const payload = await response.json();
      if (!cancelled) setStoredResults(normalizeResults(payload));
    })();
    return () => {
      cancelled = true;
    };
  }, [activeRecording?.id]);

  const startRecording = async () => {
    if (!activeCase) return;
    setError("");
    const stream = await navigator.mediaDevices.getUserMedia({
      audio: { channelCount: 1, echoCancellation: false, noiseSuppression: false },
    });
    const context = new AudioContext();
    const source = context.createMediaStreamSource(stream);
    const node = context.createScriptProcessor(4096, 1, 1);
    audioChunks.current = [];
    node.onaudioprocess = (event) => {
      audioChunks.current.push(new Float32Array(event.inputBuffer.getChannelData(0)));
    };
    source.connect(node);
    node.connect(context.destination);
    mediaStream.current = stream;
    audioContext.current = context;
    processor.current = node;
    startedAt.current = Date.now();
    timer.current = setInterval(
      () => setRecordingSeconds((Date.now() - startedAt.current) / 1000),
      100,
    );
    setRecordingSeconds(0);
    setIsRecording(true);
  };

  const stopRecording = async () => {
    const context = audioContext.current;
    if (!context || !activeCase) return;
    processor.current?.disconnect();
    mediaStream.current?.getTracks().forEach((track) => track.stop());
    if (timer.current) clearInterval(timer.current);
    const wav = encodeWav(audioChunks.current, context.sampleRate);
    await context.close();
    setIsRecording(false);
    const response = await fetch(
      `${API}/api/recordings?case_id=${encodeURIComponent(activeCase.id)}`,
      { method: "POST", headers: { "Content-Type": "audio/wav" }, body: wav },
    );
    const payload = await response.json();
    if (!response.ok) {
      setError(payload.error ?? "Could not save the recording.");
      return;
    }
    setRecordings((current) => [payload, ...current.filter((item) => item.case_id !== activeCase.id)]);
  };

  const runBenchmark = async () => {
    if (!activeRecording || !activeCase || selectedBackendIds.length === 0) return;
    setError("");
    const response = await fetch(`${API}/api/jobs`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        recording_id: activeRecording.id,
        backend_ids: selectedBackendIds,
        reference: activeCase.text,
        keywords: activeCase.keywords,
        language: "en",
        prompt: prompt || undefined,
        warmups,
        repetitions,
      }),
    });
    const payload = await response.json();
    if (!response.ok) {
      setError(payload.error ?? "Could not start the benchmark.");
      return;
    }
    setJob(payload);
  };

  const importCorpus = async () => {
    setError("");
    setImportingCorpus(true);
    try {
      if (corpusImportMode === "lines") {
        const lines = corpusText
          .split("\n")
          .map((line) => line.trim())
          .filter((line) => Boolean(line));
        if (lines.length !== 20) {
          setError("Corpus import requires exactly 20 non-empty lines.");
          return;
        }
        const response = await fetch(`${API}/api/corpus`, {
          method: "POST",
          headers: { "Content-Type": "text/plain; charset=utf-8" },
          body: lines.join("\n"),
        });
        const payload = await response.json();
        if (!response.ok) {
          setError(payload.error ?? "Could not replace corpus.");
          return;
        }
        setCorpusText(lines.join("\n"));
        await refresh();
        return;
      }

      const parsed = JSON.parse(corpusText);
      const payload = Array.isArray(parsed) ? { cases: parsed } : parsed;
      if (!payload || typeof payload !== "object" || !Array.isArray((payload as { cases?: unknown }).cases)) {
        setError("JSON corpus import must be a cases array or an object with a cases array.");
        return;
      }
      if ((payload as { cases: unknown[] }).cases.length !== 20) {
        setError("JSON corpus import must include exactly 20 cases.");
        return;
      }
      const response = await fetch(`${API}/api/corpus`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      });
      const payloadResponse = await response.json();
      if (!response.ok) {
        setError(payloadResponse.error ?? "Could not replace corpus.");
        return;
      }
      await refresh();
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "Could not replace corpus.");
    } finally {
      setImportingCorpus(false);
    }
  };

  const downloadExport = async (format: "json" | "csv") => {
    setError("");
    try {
      const response = await fetch(`${API}/api/export?format=${format}`);
      if (!response.ok) {
        const payload = await response.json();
        setError(payload.error ?? "Could not export results.");
        return;
      }
      const blob = await response.blob();
      const anchor = document.createElement("a");
      anchor.href = URL.createObjectURL(blob);
      anchor.download = `sttbench-results-${new Date().toISOString().slice(0, 19).replace(/[:T]/g, "-")}.${format}`;
      anchor.click();
      URL.revokeObjectURL(anchor.href);
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "Could not export results.");
    }
  };

  const toggleBackend = (backend: Backend) => {
    if (!backend.available) return;
    setSelected((current) => {
      const next = new Set(current);
      if (next.has(backend.id)) next.delete(backend.id);
      else next.add(backend.id);
      return next;
    });
  };

  const chooseCase = (direction: number) => {
    setCaseIndex((current) => (current + direction + cases.length) % cases.length);
    setJob(null);
    setRecordingSeconds(0);
  };

  const setResultRating = async (result: Result, rating: RatingValue) => {
    const correctedText = ratingDrafts[result.result_id] ?? ratings[result.result_id]?.corrected_text ?? "";
    const response = await fetch(`${API}/api/ratings`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        result_id: result.result_id,
        recording_id: result.recording_id,
        backend_id: result.backend_id,
        rating,
        corrected_text: correctedText || undefined,
      }),
    });
    const payload = await response.json();
    if (!response.ok) {
      setError(payload.error ?? "Could not save rating.");
      return;
    }
    const saved: ManualRating = {
      result_id: result.result_id,
      recording_id: result.recording_id,
      backend_id: result.backend_id,
      rating,
      corrected_text: payload.corrected_text,
      created_at: payload.created_at ?? new Date().toISOString(),
      updated_at: payload.updated_at ?? new Date().toISOString(),
    };
    setRatings((current) => ({ ...current, [result.result_id]: saved }));
  };

  const setResultCorrection = async (result: Result, text: string) => {
    const existing = ratings[result.result_id];
    if (!existing) return;
    const response = await fetch(`${API}/api/ratings`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        ...existing,
        result_id: result.result_id,
        corrected_text: text || undefined,
      }),
    });
    const payload = await response.json();
    if (!response.ok) {
      setError(payload.error ?? "Could not save correction.");
      return;
    }
    setRatings((current) => ({
      ...current,
      [result.result_id]: {
        ...current[result.result_id],
        result_id: result.result_id,
        corrected_text: payload.corrected_text,
        rating: payload.rating,
        created_at: payload.created_at ?? current[result.result_id]?.created_at ?? new Date().toISOString(),
        updated_at: payload.updated_at ?? new Date().toISOString(),
      },
    }));
  };

  const isRunning = job?.status === "queued" || job?.status === "running";

  const visibleResults = useMemo(() => {
    const merged = new Map<string, Result>();
    for (const result of storedResults) merged.set(result.result_id, result);
    if (job) {
      for (const result of job.results) merged.set(result.result_id, result);
    }
    return [...merged.values()];
  }, [job, storedResults]);

  return (
    <main>
      <header className="masthead">
        <div className="brand">
          <span className="brandMark" aria-hidden="true">L</span>
          <div>
            <p className="eyebrow">Luxit inference lab</p>
            <h1>Voiceprint</h1>
          </div>
        </div>
        <div className={`connection ${connected ? "online" : ""}`}>
          <span />
          {connected ? "Local service ready" : "Service offline"}
        </div>
        <div className="progressCopy">
          <strong>{completedCases}</strong>
          <span>of {cases.length || 20} recorded</span>
        </div>
      </header>

      <section className="heroGrid">
        <article className="promptPanel">
          <div className="panelTopline">
            <span>{activeCase?.category ?? "Loading corpus"}</span>
            <span>{String(caseIndex + 1).padStart(2, "0")} / {String(cases.length || 20).padStart(2, "0")}</span>
          </div>
          <blockquote>{activeCase?.text ?? "Connecting to your local benchmark corpus…"}</blockquote>
          <div className="keywordLine">
            {activeCase?.keywords.map((keyword) => <span key={keyword}>{keyword}</span>)}
          </div>
          <p className="caseNote">{activeCase?.note}</p>
          <div className="phraseNav">
            <button onClick={() => chooseCase(-1)} disabled={!cases.length} aria-label="Previous phrase">←</button>
            <div className="caseTicks" aria-label={`${completedCases} phrases recorded`}>
              {cases.map((item, index) => (
                <button
                  key={item.id}
                  onClick={() => { setCaseIndex(index); setJob(null); }}
                  className={`${index === caseIndex ? "active" : ""} ${recordings.some((recording) => recording.case_id === item.id) ? "done" : ""}`}
                  aria-label={`Phrase ${index + 1}${recordings.some((recording) => recording.case_id === item.id) ? ", recorded" : ""}`}
                />
              ))}
            </div>
            <button onClick={() => chooseCase(1)} disabled={!cases.length} aria-label="Next phrase">→</button>
          </div>
        </article>

        <aside className="recordPanel">
          <p className="eyebrow">{activeRecording ? "Take captured" : "Your turn"}</p>
          <button
            className={`recordButton ${isRecording ? "recording" : ""}`}
            onClick={isRecording ? stopRecording : startRecording}
            disabled={!connected || isRunning}
          >
            <span className="recordCore" />
            <span>{isRecording ? "Stop" : activeRecording ? "Record again" : "Record phrase"}</span>
          </button>
          <div className="recordMeta">
            <span>{isRecording ? `${recordingSeconds.toFixed(1)} seconds` : activeRecording ? "16 kHz PCM ready" : "One clean take is enough"}</span>
            <span>{activeRecording ? "Saved locally" : "Nothing leaves this Mac"}</span>
          </div>
          <button
            className="runButton"
            onClick={runBenchmark}
            disabled={!activeRecording || selectedBackendIds.length === 0 || isRunning}
          >
            {isRunning ? "Benchmarking sequentially…" : `Run ${selectedBackendIds.length || 0} selected backend${selectedBackendIds.length === 1 ? "" : "s"}`}
          </button>
        </aside>
      </section>

      {error && (
        <div className="errorBanner">
          <strong>Not ready yet.</strong>
          <span>{error}</span>
          <button onClick={refresh}>Retry</button>
        </div>
      )}

      <section className="corpusSection">
        <div className="sectionHeading">
          <div>
            <p className="eyebrow">Local phrases</p>
            <h2>Corpus editor</h2>
          </div>
          <div className="corpusMode">
            <label>
              <input
                type="radio"
                value="lines"
                checked={corpusImportMode === "lines"}
                onChange={() => setCorpusImportMode("lines")}
              />
              one phrase per line
            </label>
            <label>
              <input
                type="radio"
                value="json"
                checked={corpusImportMode === "json"}
                onChange={() => setCorpusImportMode("json")}
              />
              JSON cases array
            </label>
          </div>
        </div>
        <textarea
          className="corpusEditor"
          rows={12}
          value={corpusText}
          onChange={(event) => setCorpusText(event.target.value)}
          placeholder={
            corpusImportMode === "json"
              ? '[{"text":"your custom phrase","category":"Technical names","keywords":["term"],"note":"..."}]'
              : "phrase 1\nphrase 2\nphrase 3"
          }
        />
        <div className="importActions">
          <button className="runButton" onClick={importCorpus} disabled={importingCorpus || !corpusText.trim()}>
            {importingCorpus ? "Replacing…" : "Replace corpus"}
          </button>
          <span>Validation requires exactly 20 phrases and creates a backup before replacement.</span>
        </div>
      </section>

      <section className="workspace">
          <div className="sectionHeading">
            <div>
              <p className="eyebrow">Inference matrix</p>
              <h2>Backends</h2>
            </div>
            <div className="runSettings">
              <label>
                Family
                <select value={familyFilter} onChange={(event) => setFamilyFilter(event.target.value)}>
                  <option value="all">All families</option>
                  {familyOptions.map((family) => (
                    <option key={family} value={family}>
                      {family}
                    </option>
                  ))}
                </select>
              </label>
              <label className="readyToggle">
                <input
                  type="checkbox"
                  checked={readyOnly}
                  onChange={(event) => setReadyOnly(event.target.checked)}
                />
                Ready only
              </label>
              <label>
                Warm-ups
                <input type="number" min="0" max="3" value={warmups} onChange={(event) => setWarmups(Number(event.target.value))} />
              </label>
              <label>
                Repetitions
                <input type="number" min="1" max="5" value={repetitions} onChange={(event) => setRepetitions(Number(event.target.value))} />
            </label>
          </div>
        </div>

        <div className="backendGrid">
          {filteredBackends.map((backend) => {
            const checked = selected.has(backend.id);
            return (
              <button
                key={backend.id}
                className={`backendCard ${checked ? "selected" : ""} ${backend.available ? "" : "unavailable"}`}
                onClick={() => toggleBackend(backend)}
                aria-pressed={checked}
              >
                <span className="backendCheck">{checked ? "✓" : backend.available ? "" : "×"}</span>
                <span className="family">{backend.family}</span>
                <strong>{backend.name}</strong>
                <span className="modelName">{backend.model}</span>
                <span className="backendState">
                  {backend.available ? (backend.capabilities.persistent ? "Ready · warm worker" : "Ready · command") : backend.unavailable_reasons[0]}
                </span>
              </button>
            );
          })}
          {!backends.length && <div className="emptyState">Backend manifests are being assembled.</div>}
          {backends.length > 0 && !filteredBackends.length && (
            <div className="emptyState">No backends match the selected filters.</div>
          )}
        </div>

        <label className="promptField">
          <span>Vocabulary prompt <em>sent only to supporting models</em></span>
          <input
            value={prompt}
            onChange={(event) => setPrompt(event.target.value)}
            placeholder="Luxit, FluidAudio, PostgreSQL, Kubernetes…"
          />
        </label>
      </section>

      <section className="resultsSection">
        <div className="sectionHeading">
          <div>
            <p className="eyebrow">Measured on this machine</p>
            <h2>Results</h2>
          </div>
          <div className="resultActions">
            <button onClick={() => void downloadExport("json")} className="actionButton">
              Download JSON
            </button>
            <button onClick={() => void downloadExport("csv")} className="actionButton">
              Download CSV
            </button>
            {job && <span className={`jobState ${job.status}`}>{job.status}</span>}
          </div>
        </div>

        <div className="resultsTable">
            <div className="resultHeader">
            <span>Backend</span><span>Transcript</span><span>Accuracy</span><span>Latency</span><span>Speed</span>
          </div>
          {visibleResults.map((result) => (
            <div className="resultRow" key={result.result_id}>
              <div>
                <strong>{result.backend_name}</strong>
                <small>{result.warm ? "warm" : "cold"} · {result.family}</small>
              </div>
              <p className={result.error ? "failedText" : ""}>{result.error || result.text || "No text returned"}</p>
              <div className="metric">
                <strong>{result.scores ? `${(result.scores.word_accuracy * 100).toFixed(1)}%` : "—"}</strong>
                <small>{result.scores?.keyword_recall != null ? `${(result.scores.keyword_recall * 100).toFixed(0)}% key terms` : "word accuracy"}</small>
              </div>
              <div className="metric">
                <strong>{milliseconds(result.wall_ms)}</strong>
                <small>{result.backend_ms ? `${milliseconds(result.backend_ms)} inference` : "end to end"}</small>
              </div>
              <div className="metric speed">
                <strong>{result.realtime_factor ? `${result.realtime_factor.toFixed(1)}×` : "—"}</strong>
                <small>real time</small>
              </div>
              <div className="ratingControls">
                <span>Manual rating</span>
                <div className="ratingButtons">
                  {RATING_OPTIONS.map((option) => (
                    <button
                      key={option.value}
                      className={ratings[result.result_id]?.rating === option.value ? "selectedRating" : ""}
                      onClick={() => void setResultRating(result, option.value)}
                    >
                      {option.label}
                    </button>
                  ))}
                </div>
                <input
                  className="ratingInput"
                  value={ratingDrafts[result.result_id] ?? ratings[result.result_id]?.corrected_text ?? ""}
                  onChange={(event) => {
                    const value = event.target.value;
                    setRatingDrafts((current) => ({ ...current, [result.result_id]: value }));
                  }}
                  onBlur={(event) => {
                    if (!ratings[result.result_id]) return;
                    setResultCorrection(result, event.target.value);
                  }}
                  placeholder="Optional corrected text"
                />
              </div>
            </div>
          ))}
          {!visibleResults.length && (
            <div className="emptyResults">
              <span className="emptyGlyph">⌁</span>
              <p>Record the phrase, choose your engines, then run them against the exact same WAV.</p>
            </div>
          )}
        </div>
      </section>

      <section className="leaderboardSection">
        <div className="sectionHeading">
          <div>
            <p className="eyebrow">Aggregate view</p>
            <h2>Leaderboard</h2>
          </div>
        </div>
        <div className="leaderboardTable">
          <div className="resultHeader">
            <span>Backend</span>
            <span>Phase</span>
            <span>Accuracy</span>
            <span>Recall</span>
            <span>Latency</span>
            <span>RTF</span>
            <span>Ratings</span>
          </div>
          {summary.map((item) => (
            <div className="leaderboardRow" key={`${item.backend_id}-${item.warm ? "warm" : "cold"}`}>
              <div>
                <strong>{item.backend_name}</strong>
                <small>{item.family}</small>
              </div>
              <span>{item.warm ? "warm" : "cold"}</span>
              <strong>{percent(item.word_accuracy_mean)}</strong>
              <strong>{percent(item.keyword_recall_mean)}</strong>
              <strong>{item.latency_mean_ms == null ? "—" : `${Math.round(item.latency_mean_ms)} ms`}</strong>
              <strong>{item.realtime_factor_mean == null ? "—" : `${item.realtime_factor_mean.toFixed(1)}×`}</strong>
              <span className="leaderboardRatings">
                U:{item.manual_rating_counts.useful} E:{item.manual_rating_counts.needs_edit} W:{item.manual_rating_counts.wrong}
              </span>
            </div>
          ))}
          {!summary.length && (
            <div className="emptyResults">
              <span className="emptyGlyph">⚑</span>
              <p>Run benchmarks to populate a full backend leaderboard summary.</p>
            </div>
          )}
        </div>
      </section>

      <footer>
        <span>Record once. Decode many ways.</span>
        <span>Raw audio and results stay in <code>benchmark/data</code>.</span>
      </footer>
    </main>
  );
}
