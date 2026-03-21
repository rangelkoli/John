import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { open } from "@tauri-apps/api/shell";
import { invoke } from "@tauri-apps/api/tauri";
import { listen } from "@tauri-apps/api/event";
import { appWindow } from "@tauri-apps/api/window";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import "./App.css";

const MIN_WINDOW_WIDTH = 460;
const MIN_WINDOW_HEIGHT = 100;
const ICON_SIZE = 160;
const WINDOW_MARGIN = 16;
const MAX_CARD_SCREEN_MARGIN = WINDOW_MARGIN * 3;
const MAX_CONVERSATION_TURNS = 4;
const MAX_SPOKEN_RESPONSE_CHARS = 700;
const AUTO_DISMISS_AFTER_VOICE_MS = 1800;
const WINDOWS_ABSOLUTE_PATH_PATTERN = /^[a-zA-Z]:[\\/]/;
const QUICK_PROMPTS = [
  {
    label: "Summarize the workspace",
    prompt: "Summarize the latest changes in this workspace.",
  },
  {
    label: "Locate the overlay UI",
    prompt: "Find the file that controls this overlay UI.",
  },
  {
    label: "Draft a commit message",
    prompt: "Draft a commit message for the current git diff.",
  },
] as const;

function getAssistantShortcutLabel() {
  if (typeof navigator !== "undefined" && /Mac|iPhone|iPad|iPod/i.test(navigator.platform)) {
    return "Shift + Cmd + Space";
  }

  return "Shift + Ctrl + Space";
}

function getMaxCardHeight() {
  if (typeof window === "undefined") {
    return 640;
  }

  const screenHeight = window.screen?.availHeight || window.innerHeight || 640;
  return Math.max(MIN_WINDOW_HEIGHT, screenHeight - MAX_CARD_SCREEN_MARGIN);
}

function cn(...classes: (string | boolean | undefined)[]) {
  return classes.filter(Boolean).join(" ");
}

function getLocalFilesystemPath(href: string) {
  const [withoutFragment] = href.split("#", 1);
  const [candidate] = withoutFragment.split("?", 1);
  const decodedCandidate = decodeURIComponent(candidate);

  if (decodedCandidate.startsWith("file://")) {
    try {
      const fileUrl = new URL(decodedCandidate);
      if (fileUrl.protocol !== "file:") {
        return null;
      }

      let pathname = decodeURIComponent(fileUrl.pathname);
      if (/^\/[a-zA-Z]:/.test(pathname)) {
        pathname = pathname.slice(1);
      }

      return pathname;
    } catch {
      return null;
    }
  }

  if (/^[a-zA-Z][a-zA-Z+\-.]*:/.test(decodedCandidate)) {
    return null;
  }

  if (
    decodedCandidate.startsWith("/") ||
    decodedCandidate.startsWith("\\\\") ||
    WINDOWS_ABSOLUTE_PATH_PATTERN.test(decodedCandidate)
  ) {
    return decodedCandidate;
  }

  return null;
}

function normalizeWhitespace(value: string) {
  return value
    .replace(/\r\n/g, "\n")
    .replace(/[ \t]+\n/g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .replace(/[ \t]{2,}/g, " ")
    .trim();
}

function normalizeStreamPayload(payload: unknown) {
  if (typeof payload === "string") {
    return payload;
  }

  return JSON.stringify(payload ?? "");
}

function toStringValue(value: unknown): string {
  if (typeof value === "string") {
    return value;
  }

  if (value == null) {
    return "";
  }

  return String(value);
}

function parseAgentEvent(raw: string) {
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

function getStreamEventType(event: Record<string, unknown>) {
  return typeof event.type === "string"
    ? event.type
    : typeof event.event === "string"
      ? event.event
      : "";
}

function getStreamChunkContent(payload: Record<string, unknown>) {
  const directContent = payload.content;
  if (typeof directContent === "string") {
    return directContent;
  }

  if (typeof payload.output === "string") {
    return String(payload.output);
  }

  if (payload.data && typeof payload.data === "object" && payload.data !== null) {
    const data = payload.data as Record<string, unknown>;
    if (typeof data.content === "string") {
      return data.content;
    }

    const chunk = data.chunk;
    if (chunk && typeof chunk === "object") {
      const contentFromChunk = (chunk as Record<string, unknown>).content;
      if (typeof contentFromChunk === "string") {
        return contentFromChunk;
      }
    }

    const output = (data as Record<string, unknown>).output;
    if (typeof output === "string") {
      return output;
    }
  }

  return toStringValue(directContent);
}

function truncateText(value: string, maxLength: number) {
  if (value.length <= maxLength) {
    return value;
  }

  return `${value.slice(0, maxLength - 1).trimEnd()}…`;
}

function stripMarkdownForSpeech(value: string) {
  return normalizeWhitespace(
    value
      .replace(/```[\s\S]*?```/g, " ")
      .replace(/`([^`]+)`/g, "$1")
      .replace(/!\[[^\]]*]\([^)]*\)/g, " ")
      .replace(/\[([^\]]+)]\(([^)]+)\)/g, "$1")
      .replace(/^#{1,6}\s+/gm, "")
      .replace(/^>\s?/gm, "")
      .replace(/^\s*[-*+]\s+/gm, "")
      .replace(/^\s*\d+\.\s+/gm, "")
      .replace(/\|/g, " ")
      .replace(/https?:\/\/\S+/g, " ")
      .replace(/[*_~]/g, ""),
  );
}

interface ToolCall {
  runId: string;
  tool: string;
  input: Record<string, unknown>;
  output?: string;
  status: "running" | "completed";
}

interface ConversationTurn {
  user: string;
  assistant: string;
}

type RecordingMode = "idle" | "manual" | "handsfree";
type RequestOrigin = "text" | "voice" | "wake";

function buildAssistantPrompt(question: string, history: ConversationTurn[]) {
  if (!history.length) {
    return question;
  }

  const recentTurns = history.slice(-MAX_CONVERSATION_TURNS).map((turn, index) => {
    const user = truncateText(normalizeWhitespace(turn.user), 280);
    const assistant = truncateText(normalizeWhitespace(turn.assistant), 420);
    return `Turn ${index + 1}\nUser: ${user}\nAssistant: ${assistant}`;
  });

  return [
    "Continue this desktop assistant conversation naturally.",
    "Use the recent context only when it helps answer the latest request.",
    "Answer the latest request directly instead of replaying the full history.",
    "",
    "Recent conversation:",
    recentTurns.join("\n\n"),
    "",
    `Latest user request: ${question}`,
  ].join("\n");
}

function App() {
  const shortcutLabel = getAssistantShortcutLabel();
  const [question, setQuestion] = useState("");
  const [answer, setAnswer] = useState("");
  const [conversation, setConversation] = useState<ConversationTurn[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const [recordingMode, setRecordingMode] = useState<RecordingMode>("idle");
  const [transcribing, setTranscribing] = useState(false);
  const [isExpanded, setIsExpanded] = useState(false);
  const [isSpeaking, setIsSpeaking] = useState(false);
  const [toolCalls, setToolCalls] = useState<ToolCall[]>([]);
  const [maxCardHeight, setMaxCardHeight] = useState(() => getMaxCardHeight());

  const cardRef = useRef<HTMLElement | null>(null);
  const questionInputRef = useRef<HTMLTextAreaElement | null>(null);
  const sizeRef = useRef({ width: 0, height: 0 });
  const collapseTimeout = useRef<number | undefined>(undefined);
  const responseDismissTimeoutRef = useRef<number | undefined>(undefined);
  const answerBufferRef = useRef("");
  const pendingAskRef = useRef<{ origin: RequestOrigin; question: string } | null>(null);
  const speechUtteranceRef = useRef<SpeechSynthesisUtterance | null>(null);

  const isListening = recordingMode !== "idle";
  const isManualRecording = recordingMode === "manual";
  const activeToolCount = toolCalls.filter((toolCall) => toolCall.status === "running").length;
  const contextLabel = conversation.length
    ? `${conversation.length} recent turn${conversation.length === 1 ? "" : "s"}`
    : "Fresh context";
  const assistantStatus = isSpeaking
    ? { label: "Speaking", tone: "warm" }
    : loading
      ? { label: "Thinking", tone: "cool" }
      : transcribing
        ? { label: "Transcribing", tone: "cool" }
        : recordingMode === "handsfree"
          ? { label: "Hands-free", tone: "listening" }
          : recordingMode === "manual"
            ? { label: "Listening", tone: "listening" }
            : { label: "Ready", tone: "idle" };
  const composerModeLabel = isListening
    ? "Voice capture active"
    : transcribing
      ? "Turning speech into text"
      : loading
        ? "Streaming response"
        : conversation.length
          ? `${conversation.length} turn${conversation.length === 1 ? "" : "s"} in memory`
          : "Text and voice ready";
  const showSuggestions = !question.trim() && !answer && !error && !loading && !transcribing && !isListening;

  const assistantSubtitle = isSpeaking
    ? "Speaking your answer aloud."
    : loading
      ? "Working through your request."
      : transcribing
        ? "Turning your voice into text."
        : recordingMode === "handsfree"
          ? "Listening hands-free. Stop talking when you're done."
          : recordingMode === "manual"
            ? "Listening. Click the mic again when you're done."
            : question.trim()
              ? "Press Enter to send, or Shift+Enter for a new line."
              : `Say "Hey John" or press ${shortcutLabel} to start talking.`;

  const inputPlaceholder = recordingMode === "handsfree"
    ? "Listening hands-free..."
    : recordingMode === "manual"
      ? "Listening... click the mic again when you're done"
      : transcribing
        ? "Transcribing..."
        : loading
          ? "Working on it..."
          : isSpeaking
            ? "Speaking the answer aloud..."
            : "Ask anything, or just say it out loud";

  const focusQuestionInput = useCallback(() => {
    window.setTimeout(() => {
      const input = questionInputRef.current;
      if (!input) {
        return;
      }

      input.focus();
      const caret = input.value.length;
      input.setSelectionRange(caret, caret);
    }, 140);
  }, []);

  const stopSpeaking = useCallback(() => {
    window.clearTimeout(responseDismissTimeoutRef.current);

    if (typeof window !== "undefined" && "speechSynthesis" in window) {
      window.speechSynthesis.cancel();
    }

    speechUtteranceRef.current = null;
    setIsSpeaking(false);
  }, []);

  const dismissAssistant = useCallback(() => {
    stopSpeaking();
    window.clearTimeout(collapseTimeout.current);

    if (isManualRecording) {
      void invoke("cancel_voice_recording").catch(() => undefined);
      setRecordingMode("idle");
    }

    setIsExpanded(false);
    collapseTimeout.current = window.setTimeout(() => {
      void appWindow.hide();
      void invoke("resume_wake_phrase_listener");
    }, 280);
  }, [isManualRecording, stopSpeaking]);

  const scheduleAutoDismiss = useCallback(() => {
    window.clearTimeout(responseDismissTimeoutRef.current);
    responseDismissTimeoutRef.current = window.setTimeout(() => {
      dismissAssistant();
    }, AUTO_DISMISS_AFTER_VOICE_MS);
  }, [dismissAssistant]);

  const speakResponse = useCallback((markdown: string, autoDismiss: boolean) => {
    const speechText = truncateText(stripMarkdownForSpeech(markdown), MAX_SPOKEN_RESPONSE_CHARS);
    if (!speechText) {
      if (autoDismiss) {
        scheduleAutoDismiss();
      }
      return;
    }

    stopSpeaking();

    if (typeof window === "undefined" || !("speechSynthesis" in window)) {
      if (autoDismiss) {
        scheduleAutoDismiss();
      }
      return;
    }

    const utterance = new SpeechSynthesisUtterance(speechText);
    utterance.lang = navigator.language || "en-US";
    utterance.rate = 1.02;
    utterance.pitch = 1;
    utterance.onstart = () => setIsSpeaking(true);

    const finishSpeaking = () => {
      speechUtteranceRef.current = null;
      setIsSpeaking(false);
      if (autoDismiss) {
        scheduleAutoDismiss();
      }
    };

    utterance.onend = finishSpeaking;
    utterance.onerror = finishSpeaking;

    speechUtteranceRef.current = utterance;
    window.speechSynthesis.speak(utterance);
  }, [scheduleAutoDismiss, stopSpeaking]);

  const ask = useCallback(async (nextQuestion?: string, origin: RequestOrigin = "text") => {
    const trimmed = (nextQuestion ?? question).trim();
    if (!trimmed || loading) {
      return;
    }

    setIsExpanded(true);
    stopSpeaking();
    setLoading(true);
    setError("");
    setAnswer("");
    setToolCalls([]);
    answerBufferRef.current = "";
    pendingAskRef.current = { origin, question: trimmed };

    if (nextQuestion !== undefined) {
      setQuestion(trimmed);
    }

    try {
      await invoke("ask_deep_agent_stream", {
        question: buildAssistantPrompt(trimmed, conversation),
      });
    } catch (err: unknown) {
      pendingAskRef.current = null;
      setError(err instanceof Error ? err.message : String(err));
      setLoading(false);
    }
  }, [conversation, loading, question, stopSpeaking]);

  const startRecording = useCallback(async () => {
    stopSpeaking();
    setError("");

    try {
      await invoke("pause_wake_phrase_listener");
      await invoke("start_voice_recording");
      setRecordingMode("manual");
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : String(err));
    }
  }, [stopSpeaking]);

  const stopRecordingAndTranscribe = useCallback(async (options?: {
    autoSubmit?: boolean;
    origin?: RequestOrigin;
  }) => {
    const origin = options?.origin ?? "voice";

    setRecordingMode("idle");
    setTranscribing(true);
    setError("");

    try {
      const text = await invoke<string>("stop_and_transcribe");
      const trimmed = text.trim();
      setQuestion(text);
      focusQuestionInput();

      if (!trimmed) {
        setError("I didn't catch that. Try again.");
        return;
      }

      if (options?.autoSubmit) {
        await ask(trimmed, origin);
      }
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setTranscribing(false);
    }
  }, [ask, focusQuestionInput]);

  const captureVoiceQuery = useCallback(async () => {
    stopSpeaking();
    setError("");

    try {
      await invoke("pause_wake_phrase_listener");
      setRecordingMode("handsfree");

      const text = await invoke<string>("capture_voice_query");
      const trimmed = text.trim();
      setQuestion(text);
      focusQuestionInput();

      if (!trimmed) {
        setError("I didn't catch that. Try again.");
        return;
      }

      await ask(trimmed, "wake");
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setRecordingMode("idle");
    }
  }, [ask, focusQuestionInput, stopSpeaking]);

  const toggleRecording = useCallback(async () => {
    if (recordingMode === "manual") {
      await stopRecordingAndTranscribe();
      return;
    }

    if (recordingMode === "handsfree") {
      return;
    }

    await startRecording();
  }, [recordingMode, startRecording, stopRecordingAndTranscribe]);

  const handleWakePhraseDetected = useCallback(async () => {
    window.clearTimeout(collapseTimeout.current);
    window.clearTimeout(responseDismissTimeoutRef.current);
    setIsExpanded(true);
    focusQuestionInput();

    if (recordingMode !== "idle" || transcribing || loading) {
      return;
    }

    await captureVoiceQuery();
  }, [captureVoiceQuery, focusQuestionInput, loading, recordingMode, transcribing]);

  const handleMarkdownLinkClick = useCallback(async (href?: string) => {
    if (!href) {
      return;
    }

    setError("");

    try {
      const localPath = getLocalFilesystemPath(href);
      if (localPath) {
        await invoke("reveal_path_in_file_manager", { path: localPath });
        return;
      }

      await open(href);
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : String(err));
    }
  }, []);

  const handleSuggestionClick = useCallback((prompt: string) => {
    setQuestion(prompt);
    focusQuestionInput();
  }, [focusQuestionInput]);

  useEffect(() => {
    const syncMaxCardHeight = () => {
      setMaxCardHeight(getMaxCardHeight());
    };

    syncMaxCardHeight();
    window.addEventListener("resize", syncMaxCardHeight);

    return () => {
      window.removeEventListener("resize", syncMaxCardHeight);
    };
  }, []);

  useLayoutEffect(() => {
    let frame = 0;
    let resizeTimeout: number | undefined;
    let collapsedTimeout: number | undefined;

    const syncWindowSize = async () => {
      const card = cardRef.current;
      if (!isExpanded) {
        if (sizeRef.current.width !== ICON_SIZE || sizeRef.current.height !== ICON_SIZE) {
          window.clearTimeout(collapsedTimeout);
          collapsedTimeout = window.setTimeout(async () => {
            if (!isExpanded) {
              sizeRef.current = { width: ICON_SIZE, height: ICON_SIZE };
              await invoke("sync_window_size", { width: ICON_SIZE, height: ICON_SIZE });
            }
          }, 350);
        }
        return;
      }

      if (!card) {
        if (sizeRef.current.width === ICON_SIZE || sizeRef.current.width === 0) {
          sizeRef.current = { width: MIN_WINDOW_WIDTH, height: 350 };
          await invoke("sync_window_size", { width: MIN_WINDOW_WIDTH, height: 350 });
        }
        return;
      }

      window.clearTimeout(resizeTimeout);
      resizeTimeout = window.setTimeout(async () => {
        const element = cardRef.current;
        if (!element || !isExpanded) {
          return;
        }

        const rect = element.getBoundingClientRect();
        const nextWidth = Math.max(MIN_WINDOW_WIDTH, Math.ceil(rect.width + WINDOW_MARGIN));
        const nextHeight = Math.max(
          MIN_WINDOW_HEIGHT,
          Math.min(maxCardHeight + WINDOW_MARGIN, Math.ceil(rect.height + WINDOW_MARGIN)),
        );

        if (
          Math.abs(nextWidth - sizeRef.current.width) < 2 &&
          Math.abs(nextHeight - sizeRef.current.height) < 2
        ) {
          return;
        }

        sizeRef.current = { width: nextWidth, height: nextHeight };
        await invoke("sync_window_size", { width: nextWidth, height: nextHeight });
      }, 16);
    };

    const scheduleSync = () => {
      cancelAnimationFrame(frame);
      frame = requestAnimationFrame(() => {
        void syncWindowSize();
      });
    };

    const observer = new ResizeObserver(scheduleSync);
    if (cardRef.current) {
      observer.observe(cardRef.current);
    }

    const mutationObserver = new MutationObserver(scheduleSync);
    if (cardRef.current) {
      mutationObserver.observe(cardRef.current, {
        childList: true,
        subtree: true,
        characterData: true,
      });
    }

    window.addEventListener("resize", scheduleSync);
    void syncWindowSize();

    return () => {
      cancelAnimationFrame(frame);
      window.clearTimeout(resizeTimeout);
      window.clearTimeout(collapsedTimeout);
      observer.disconnect();
      mutationObserver.disconnect();
      window.removeEventListener("resize", scheduleSync);
    };
  }, [answer, error, isExpanded, isListening, isSpeaking, loading, maxCardHeight, question, toolCalls, transcribing]);

  useEffect(() => {
    const card = cardRef.current;
    if (!card || !isExpanded) {
      return;
    }

    card.scrollTop = card.scrollHeight;
  }, [answer, error, isExpanded, loading, toolCalls]);

  useEffect(() => {
    const handleBlur = () => {
      if (recordingMode !== "idle" || transcribing || loading || isSpeaking) {
        return;
      }

      dismissAssistant();
    };

    window.addEventListener("blur", handleBlur);

    return () => {
      window.removeEventListener("blur", handleBlur);
    };
  }, [dismissAssistant, isSpeaking, loading, recordingMode, transcribing]);

  useEffect(() => {
    const finalizePendingTurn = () => {
      const pending = pendingAskRef.current;
      pendingAskRef.current = null;

      const finalAnswer = answerBufferRef.current.trim();
      if (!pending || !finalAnswer) {
        return;
      }

      const conversationTurn = {
        user: pending.question,
        assistant: truncateText(stripMarkdownForSpeech(finalAnswer), 500),
      };

      setConversation((prev) => [...prev, conversationTurn].slice(-MAX_CONVERSATION_TURNS));

      if (pending.origin === "voice" || pending.origin === "wake") {
        speakResponse(finalAnswer, pending.origin === "wake");
      }
    };

      const unlistenPromise = listen("agent-stream", (event) => {
      const data = normalizeStreamPayload(event.payload);
      const parsed = typeof data === "string" ? parseAgentEvent(data) : null;

      if (parsed && typeof parsed === "object" && parsed !== null) {
        const streamPayload = parsed as Record<string, unknown>;
        const eventType = getStreamEventType(streamPayload);

        if (eventType === "chunk" || eventType === "on_chat_model_stream") {
          const content = getStreamChunkContent(streamPayload);
          answerBufferRef.current += content;
          setAnswer((prev) => prev + content);
          setIsExpanded(true);
        } else if (eventType === "tool_call" || eventType === "on_tool_start") {
          const runId = toStringValue(streamPayload.run_id ?? streamPayload.id);
          const toolName = toStringValue(streamPayload.tool ?? streamPayload.name ?? "unknown");
          const input = (streamPayload.input ?? streamPayload.data ?? {}) as Record<string, unknown>;
          setToolCalls((prev) => [
            ...prev,
            {
              runId,
              tool: toStringValue(toolName),
              input: input as Record<string, unknown>,
              status: "running",
            },
          ]);
          setIsExpanded(true);
        } else if (eventType === "tool_result" || eventType === "on_tool_end") {
          const runId = toStringValue(streamPayload.run_id ?? streamPayload.id);
          const toolName = toStringValue(streamPayload.tool ?? streamPayload.name ?? "unknown");
          const output = getStreamChunkContent(streamPayload);
          setToolCalls((prev) =>
            prev.map((toolCall) =>
              toolCall.runId === runId
                ? { ...toolCall, output, status: "completed" }
                : toolCall,
            ),
          );
          if (output) {
            setToolCalls((prev) =>
              prev.map((toolCall) =>
                toolCall.runId === runId ? { ...toolCall, output, status: "completed" } : toolCall,
              ),
            );
          }

          if (!toolName && !output) {
            setToolCalls((prev) =>
              prev.map((toolCall) =>
                toolCall.runId === runId ? { ...toolCall, tool: "tool", status: "completed" } : toolCall,
              ),
            );
          }
        } else if (eventType === "error" || eventType === "on_error") {
          pendingAskRef.current = null;
          setError(getStreamChunkContent(streamPayload) || "Agent failed.");
          setLoading(false);
        } else if (eventType === "done" || eventType === "on_chain_end") {
          const finalContent = getStreamChunkContent(streamPayload);
          if (finalContent && !answerBufferRef.current) {
            answerBufferRef.current += finalContent;
            setAnswer((prev) => prev + finalContent);
          }
          if (!finalContent && !answerBufferRef.current.trim()) {
            setError("No response text was returned.");
          }
          setLoading(false);
          finalizePendingTurn();
        }
      } else if (typeof data === "string" && data.trim()) {
        if (data) {
          answerBufferRef.current += data;
          setAnswer((prev) => prev + data);
        }
      }
    });

    const unlistenErrorPromise = listen("agent-stream-error", (event) => {
      pendingAskRef.current = null;
      setError(typeof event.payload === "string" ? event.payload : JSON.stringify(event.payload ?? ""));
      setLoading(false);
    });

    return () => {
      unlistenPromise.then((fn) => fn());
      unlistenErrorPromise.then((fn) => fn());
    };
  }, [speakResponse]);

  useEffect(() => {
    const unlistenWakePromise = listen("wake-phrase-detected", () => {
      void handleWakePhraseDetected();
    });

    return () => {
      unlistenWakePromise.then((fn) => fn());
    };
  }, [handleWakePhraseDetected]);

  useEffect(() => () => {
    stopSpeaking();
    window.clearTimeout(collapseTimeout.current);
    window.clearTimeout(responseDismissTimeoutRef.current);
  }, [stopSpeaking]);

  const handleKeyDown = (event: React.KeyboardEvent) => {
    if (event.key === "Escape") {
      event.preventDefault();
      if (!loading && !transcribing && recordingMode === "idle") {
        dismissAssistant();
      }
      return;
    }

    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      void ask();
    }
  };

  return (
    <main className="overlay-shell">
      <div className={cn("assistant-container", isExpanded && "expanded")}>
        <section
          ref={cardRef}
          className={cn("assistant-card", isExpanded && "visible")}
          style={isExpanded ? { maxHeight: `${maxCardHeight}px` } : undefined}
          role="dialog"
          aria-label="Assistant panel"
        >
          <header className="assistant-header">
            <div className="assistant-header-main">
              <div className="assistant-orb-container">
                <div
                  className={cn(
                    "assistant-orb",
                    isListening && "listening",
                    loading && "thinking",
                    isSpeaking && "speaking",
                  )}
                  aria-hidden="true"
                />
              </div>
              <div className="assistant-header-text">
                <span className="assistant-eyebrow">Desktop copilot</span>
                <div className="assistant-title-row">
                  <h1 className="assistant-title">John</h1>
                  <span className={cn("assistant-status-pill", assistantStatus.tone)}>
                    {assistantStatus.label}
                  </span>
                </div>
                <p className="assistant-subtitle">{assistantSubtitle}</p>
              </div>
            </div>
            <div className="assistant-header-side">
              <span className="assistant-context-chip">{contextLabel}</span>
              <kbd className="assistant-shortcut" aria-label={`Shortcut ${shortcutLabel}`}>
                {shortcutLabel}
              </kbd>
            </div>
          </header>

          <div className={cn("assistant-input-container", isListening && "listening")}>
            <div className="assistant-input-topline">
              <span className="assistant-input-label">Prompt</span>
              <span className="assistant-input-mode">{composerModeLabel}</span>
            </div>
            <textarea
              id="question-input"
              ref={questionInputRef}
              className="assistant-input"
              placeholder={inputPlaceholder}
              value={question}
              onChange={(event) => setQuestion(event.target.value)}
              onKeyDown={handleKeyDown}
              disabled={loading || transcribing || isListening}
              rows={3}
              aria-label="Your question"
            />
            <div className="assistant-input-footer">
              <div className="assistant-hints" aria-hidden="true">
                <span className="assistant-hint-chip">Enter to send</span>
                <span className="assistant-hint-chip">Shift+Enter for a new line</span>
                <span className="assistant-hint-chip">Voice-ready</span>
              </div>
              <div className="assistant-input-actions">
                <button
                  type="button"
                  className={cn("assistant-mic-button", isListening && "recording")}
                  onClick={() => void toggleRecording()}
                  disabled={loading || transcribing || recordingMode === "handsfree"}
                  title={
                    isManualRecording
                      ? "Stop recording and transcribe"
                      : "Start voice input"
                  }
                  aria-label={isManualRecording ? "Stop recording" : "Start voice input"}
                >
                  <svg
                    width="16"
                    height="16"
                    viewBox="0 0 24 24"
                    fill="none"
                    stroke="currentColor"
                    strokeWidth="2"
                    strokeLinecap="round"
                    strokeLinejoin="round"
                    aria-hidden="true"
                  >
                    <path d="M12 1a3 3 0 0 0-3 3v8a3 3 0 0 0 6 0V4a3 3 0 0 0-3-3z" />
                    <path d="M19 10v2a7 7 0 0 1-14 0v-2" />
                    <line x1="12" y1="19" x2="12" y2="23" />
                    <line x1="8" y1="23" x2="16" y2="23" />
                  </svg>
                </button>
                <button
                  type="button"
                  className="assistant-button"
                  onClick={() => void ask()}
                  disabled={loading || isListening || transcribing || !question.trim()}
                  aria-label="Ask question"
                >
                  {loading ? (
                    <span className="button-loading">
                      <span className="button-dots" aria-hidden="true">
                        <span />
                        <span />
                        <span />
                      </span>
                      Thinking
                    </span>
                  ) : (
                    <span className="button-text">
                      <svg
                        width="14"
                        height="14"
                        viewBox="0 0 24 24"
                        fill="none"
                        stroke="currentColor"
                        strokeWidth="2.5"
                        strokeLinecap="round"
                        strokeLinejoin="round"
                        aria-hidden="true"
                      >
                        <path d="M22 2 11 13" />
                        <polygon points="22 2 15 22 11 13 2 9 22 2" />
                      </svg>
                      Ask
                      <span className="button-hint">↵</span>
                    </span>
                  )}
                </button>
              </div>
            </div>
          </div>

          {showSuggestions && (
            <div className="assistant-suggestions" aria-label="Suggested prompts">
              {QUICK_PROMPTS.map((item) => (
                <button
                  key={item.label}
                  type="button"
                  className="assistant-suggestion"
                  onClick={() => handleSuggestionClick(item.prompt)}
                >
                  <span className="assistant-suggestion-label">{item.label}</span>
                  <span className="assistant-suggestion-text">{item.prompt}</span>
                </button>
              ))}
            </div>
          )}

          {(loading || transcribing || isListening || isSpeaking) && (
            <div className="assistant-thinking" aria-live="polite">
              <div className="thinking-wave" aria-hidden="true">
                <span />
                <span />
                <span />
                <span />
                <span />
              </div>
              <p className="thinking-text">
                {isSpeaking
                  ? "John is speaking..."
                  : transcribing
                    ? "John is transcribing your request..."
                    : isListening
                      ? "John is listening..."
                      : "John is working on your question..."}
              </p>
            </div>
          )}

          {toolCalls.length > 0 && (
            <div className="tool-calls" aria-live="polite">
              <div className="tool-calls-header">
                <div className="tool-calls-title">
                  <svg
                    width="12"
                    height="12"
                    viewBox="0 0 24 24"
                    fill="none"
                    stroke="currentColor"
                    strokeWidth="2"
                    strokeLinecap="round"
                    strokeLinejoin="round"
                    aria-hidden="true"
                  >
                    <path d="M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.77-3.77a6 6 0 0 1-7.94 7.94l-6.91 6.91a2.12 2.12 0 0 1-3-3l6.91-6.91a6 6 0 0 1 7.94-7.94l-3.76 3.76z" />
                  </svg>
                  <span>Tool calls</span>
                </div>
                <span className="tool-call-count">
                  {activeToolCount > 0 ? `${activeToolCount} live` : `${toolCalls.length} complete`}
                </span>
              </div>
              {toolCalls.map((toolCall) => (
                <div key={toolCall.runId} className={`tool-call-item ${toolCall.status}`}>
                  <div className="tool-call-meta">
                    <div className="tool-call-name">
                      {toolCall.status === "running" ? (
                        <span className="tool-call-spinner" aria-hidden="true" />
                      ) : (
                        <svg
                          width="12"
                          height="12"
                          viewBox="0 0 24 24"
                          fill="none"
                          stroke="currentColor"
                          strokeWidth="2.5"
                          strokeLinecap="round"
                          strokeLinejoin="round"
                          aria-hidden="true"
                        >
                          <polyline points="20 6 9 17 4 12" />
                        </svg>
                      )}
                      <code>{toolCall.tool}</code>
                    </div>
                    <span className={cn("tool-call-state", toolCall.status)}>
                      {toolCall.status === "running" ? "Running" : "Done"}
                    </span>
                  </div>
                  {toolCall.output && (
                    <pre className="tool-call-output">{toolCall.output}</pre>
                  )}
                </div>
              ))}
            </div>
          )}

          {error && (
            <div className="assistant-error" role="alert">
              <svg
                width="16"
                height="16"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                strokeWidth="2"
                strokeLinecap="round"
                strokeLinejoin="round"
                aria-hidden="true"
              >
                <circle cx="12" cy="12" r="10" />
                <line x1="15" y1="9" x2="9" y2="15" />
                <line x1="9" y1="9" x2="15" y2="15" />
              </svg>
              <span>{error}</span>
            </div>
          )}

          {answer && (
            <article className="assistant-answer" aria-live="polite">
              <div className="answer-header">
                <div className="answer-title">
                  <svg
                    width="14"
                    height="14"
                    viewBox="0 0 24 24"
                    fill="none"
                    stroke="currentColor"
                    strokeWidth="2"
                    strokeLinecap="round"
                    strokeLinejoin="round"
                    aria-hidden="true"
                  >
                    <path d="M12 2a4 4 0 0 1 4 4c0 1.95-2 3-2 8h-4c0-5-2-6.05-2-8a4 4 0 0 1 4-4z" />
                    <line x1="10" y1="18" x2="14" y2="18" />
                    <line x1="10" y1="22" x2="14" y2="22" />
                  </svg>
                  <span>Response</span>
                </div>
                <span className="answer-state">{loading ? "Streaming" : "Ready"}</span>
              </div>
              <div className="answer-content">
                <ReactMarkdown
                  remarkPlugins={[remarkGfm]}
                  components={{
                    a: ({ href, children, className, title, ...props }) => {
                      const localPath = href ? getLocalFilesystemPath(href) : null;

                      return (
                        <a
                          {...props}
                          href={href}
                          className={cn(className, localPath ? "filesystem-link" : undefined)}
                          title={title ?? (localPath ? `Reveal in file manager: ${localPath}` : undefined)}
                          onClick={(event) => {
                            event.preventDefault();
                            void handleMarkdownLinkClick(href);
                          }}
                        >
                          {children}
                        </a>
                      );
                    },
                  }}
                >
                  {answer}
                </ReactMarkdown>
              </div>
            </article>
          )}
        </section>
      </div>
    </main>
  );
}

export default App;
