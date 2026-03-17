import { useLayoutEffect, useEffect, useRef, useState, useCallback } from "react";
import { invoke } from "@tauri-apps/api/tauri";
import { listen } from "@tauri-apps/api/event";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import "./App.css";

const MIN_WINDOW_WIDTH = 460;
const MIN_WINDOW_HEIGHT = 100;
const ICON_SIZE = 160;
const WINDOW_MARGIN = 16;

/**
 * Utility for conditional class names
 */
function cn(...classes: (string | boolean | undefined)[]) {
  return classes.filter(Boolean).join(" ");
}

function App() {
  const [question, setQuestion] = useState("");
  const [answer, setAnswer] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const [isRecording, setIsRecording] = useState(false);
  const [transcribing, setTranscribing] = useState(false);
  const [isExpanded, setIsExpanded] = useState(false);
  
  const cardRef = useRef<HTMLElement | null>(null);
  const containerRef = useRef<HTMLDivElement | null>(null);
  const sizeRef = useRef({ width: 0, height: 0 });
  const collapseTimeout = useRef<number | undefined>(undefined);

  const toggleRecording = useCallback(async () => {
    if (isRecording) {
      setIsRecording(false);
      setTranscribing(true);
      setError("");
      try {
        const text = await invoke<string>("stop_and_transcribe");
        setQuestion(text);
      } catch (err: unknown) {
        setError(err instanceof Error ? err.message : String(err));
      } finally {
        setTranscribing(false);
      }
    } else {
      setError("");
      try {
        await invoke("start_voice_recording");
        setIsRecording(true);
      } catch (err: unknown) {
        setError(err instanceof Error ? err.message : String(err));
      }
    }
  }, [isRecording]);

  const handleMouseEnter = useCallback(() => {
    window.clearTimeout(collapseTimeout.current);
    setIsExpanded(true);
  }, []);

  const handleMouseLeave = useCallback(() => {
    collapseTimeout.current = window.setTimeout(() => {
      setIsExpanded(false);
    }, 300);
  }, []);

  useLayoutEffect(() => {
    let frame = 0;
    let resizeTimeout: number | undefined;
    let collapsedTimeout: number | undefined;

    const syncWindowSize = async () => {
      const card = cardRef.current;
      if (!isExpanded) {
        // Collapsing: wait for CSS transitions to finish before shrinking window
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

      // Expanding: first set a generous window size so content can render
      if (!card) {
        if (sizeRef.current.width === ICON_SIZE || sizeRef.current.width === 0) {
          sizeRef.current = { width: MIN_WINDOW_WIDTH, height: 350 };
          await invoke("sync_window_size", { width: MIN_WINDOW_WIDTH, height: 350 });
        }
        return;
      }

      // Debounce rapid resizes (e.g. streaming content)
      window.clearTimeout(resizeTimeout);
      resizeTimeout = window.setTimeout(async () => {
        const el = cardRef.current;
        if (!el || !isExpanded) return;

        const rect = el.getBoundingClientRect();
        const nextWidth = Math.max(MIN_WINDOW_WIDTH, Math.ceil(rect.width + WINDOW_MARGIN));
        const nextHeight = Math.max(MIN_WINDOW_HEIGHT, Math.ceil(rect.height + WINDOW_MARGIN));

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
    if (cardRef.current) observer.observe(cardRef.current);

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
  }, [answer, error, loading, question, isRecording, transcribing, isExpanded]);

  // Collapse when window loses focus
  useEffect(() => {
    const handleBlur = () => {
      setIsExpanded(false);
    };

    const handleFocus = () => {
      // Optionally expand on focus if needed
    };

    window.addEventListener("blur", handleBlur);
    window.addEventListener("focus", handleFocus);

    return () => {
      window.removeEventListener("blur", handleBlur);
      window.removeEventListener("focus", handleFocus);
    };
  }, []);

  const ask = async () => {
    const trimmed = question.trim();
    if (!trimmed || loading) return;

    setLoading(true);
    setError("");
    setAnswer("");
    
    try {
      // Start streaming
      await invoke("ask_deep_agent_stream", { question: trimmed });
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : String(err));
      setLoading(false);
    }
  };

  // Listen for stream events
  useEffect(() => {
    const unlistenPromise = listen("agent-stream", (event) => {
      const data = event.payload as string;
      try {
        const parsed = JSON.parse(data);
        if (parsed.type === "chunk") {
          setAnswer((prev) => prev + parsed.content);
        } else if (parsed.type === "done") {
          setLoading(false);
        }
      } catch {
        // If not JSON, treat as raw content
        setAnswer((prev) => prev + data);
      }
    });

    const unlistenErrorPromise = listen("agent-stream-error", (event) => {
      setError(event.payload as string);
      setLoading(false);
    });

    return () => {
      unlistenPromise.then((fn) => fn());
      unlistenErrorPromise.then((fn) => fn());
    };
  }, []);

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
      e.preventDefault();
      ask();
    }
  };

  return (
    <main className="overlay-shell">
      <div
        ref={containerRef}
        className={cn("assistant-container", isExpanded && "expanded")}
        onMouseEnter={handleMouseEnter}
        onMouseLeave={handleMouseLeave}
      >
        <button 
          className={cn("assistant-icon-trigger", isExpanded && "hidden")} 
          aria-label="Open assistant"
          onClick={() => setIsExpanded(true)}
        >
          <div className="assistant-orb-small" aria-hidden="true" />
        </button>

        <section
          ref={cardRef}
          className={cn("assistant-card", isExpanded && "visible")}
          role="dialog"
          aria-label="Assistant panel"
        >
          <header className="assistant-header">
            <div className="assistant-orb-container">
              <div className="assistant-orb" aria-hidden="true" />
            </div>
            <div className="assistant-header-text">
              <h1 className="assistant-title">John</h1>
              <p className="assistant-subtitle">Ask the app any question.</p>
            </div>
            <kbd className="assistant-shortcut" aria-label="Keyboard shortcut Command Shift Space">⌘⇧␣</kbd>
          </header>

          <div className="assistant-input-container">
            <textarea
              id="question-input"
              className="assistant-input"
              placeholder={isRecording ? "Recording... click mic to stop" : transcribing ? "Transcribing..." : "What can I help you with?"}
              value={question}
              onChange={(e) => setQuestion(e.target.value)}
              onKeyDown={handleKeyDown}
              disabled={loading}
              rows={2}
              aria-label="Your question"
            />
            <div className="assistant-input-actions">
              <button
                className={cn("assistant-mic-button", isRecording && "recording")}
                onClick={toggleRecording}
                disabled={loading || transcribing}
                title={isRecording ? "Stop recording and transcribe" : "Start voice input"}
                aria-label={isRecording ? "Stop recording" : "Start voice input"}
              >
                <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
                  <path d="M12 1a3 3 0 0 0-3 3v8a3 3 0 0 0 6 0V4a3 3 0 0 0-3-3z"/>
                  <path d="M19 10v2a7 7 0 0 1-14 0v-2"/>
                  <line x1="12" y1="19" x2="12" y2="23"/>
                  <line x1="8" y1="23" x2="16" y2="23"/>
                </svg>
              </button>
              <button
                className="assistant-button"
                onClick={ask}
                disabled={loading || !question.trim()}
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
                    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
                      <path d="M22 2 11 13"/><polygon points="22 2 15 22 11 13 2 9 22 2"/>
                    </svg>
                    Ask
                    <span className="button-hint">⌘↵</span>
                  </span>
                )}
              </button>
            </div>
          </div>

          {loading && (
            <div className="assistant-thinking" aria-live="polite">
              <div className="thinking-wave" aria-hidden="true">
                <span /><span /><span /><span /><span />
              </div>
              <p className="thinking-text">John is working on your question...</p>
            </div>
          )}

          {error && (
            <div className="assistant-error" role="alert">
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
                <circle cx="12" cy="12" r="10"/><line x1="15" y1="9" x2="9" y2="15"/><line x1="9" y1="9" x2="15" y2="15"/>
              </svg>
              <span>{error}</span>
            </div>
          )}

          {answer && (
            <article className="assistant-answer" aria-live="polite">
              <div className="answer-header">
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
                  <path d="M12 2a4 4 0 0 1 4 4c0 1.95-2 3-2 8h-4c0-5-2-6.05-2-8a4 4 0 0 1 4-4z"/><line x1="10" y1="18" x2="14" y2="18"/><line x1="10" y1="22" x2="14" y2="22"/>
                </svg>
                <span>Response</span>
              </div>
              <div className="answer-content">
                <ReactMarkdown remarkPlugins={[remarkGfm]}>
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