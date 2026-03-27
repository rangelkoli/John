import { existsSync } from "node:fs";
import { join, dirname } from "node:path";

type WakeListenerEvent =
  | { type: "wake" }
  | { type: "sleep" }
  | { type: "command"; text: string }
  | { type: "command_audio"; path: string }
  | { type: "status"; message: string }
  | { type: "error"; message: string };

type EventCallback = (event: WakeListenerEvent) => void;

const WAKE_PHRASES = ["hey john", "hey jon", "a john", "hey jan", "hey sean", "hey joe"];
const SLEEP_PHRASES = ["bye john", "bye jon", "bye jan", "goodbye john", "goodbye jon"];

export class WakeWordListener {
  private proc: ReturnType<typeof Bun.spawn> | null = null;
  private callback: EventCallback;
  private binaryPath: string;
  private sourcePath: string;
  private state: "idle" | "wake-listening" | "command-listening" = "idle";
  private commandBuffer = "";
  private commandTimeout: ReturnType<typeof setTimeout> | null = null;
  private lastTranscriptLength = 0;
  private lastStatusMessage = "";
  private fallbackCommand = "";

  constructor(callback: EventCallback) {
    this.callback = callback;

    // Resolve paths — the binary is compiled into src/native/ during build.
    // In dev mode, we can find it relative to the project root.
    // We detect the project root by walking up from the CWD or import.meta.dir.
    const candidates = [
      // Direct source tree path (works during development)
      join(process.cwd(), "..", "..", "..", "..", "src", "native"),
      // Relative to import.meta (Bun entry in Resources/)
      join(dirname(import.meta.dir), "..", "..", "..", "..", "src", "native"),
      // Explicit fallback for the project on this volume
      "/Volumes/RANGEL/john/src/native",
    ];

    let nativeDir = candidates.find(d => existsSync(join(d, "wake-listener.swift"))) || candidates[2];

    this.sourcePath = join(nativeDir, "wake-listener.swift");
    this.binaryPath = join(nativeDir, "wake-listener");
  }

  async start() {
    // Compile the Swift binary if needed
    await this.ensureBinary();

    // Spawn the listener process
    this.spawnListener();
  }

  stop() {
    if (this.proc) {
      this.proc.kill();
      this.proc = null;
    }
    this.state = "idle";
    if (this.commandTimeout) {
      clearTimeout(this.commandTimeout);
      this.commandTimeout = null;
    }
  }

  /** Send a command to the Swift process via stdin */
  private sendCommand(cmd: string) {
    if (this.proc?.stdin) {
      const writer = this.proc.stdin.getWriter();
      writer.write(new TextEncoder().encode(cmd + "\n"));
      writer.releaseLock();
    }
  }

  /** Switch to command capture mode (called after wake word detected) */
  listenForCommand() {
    this.state = "command-listening";
    this.commandBuffer = "";
    this.lastTranscriptLength = 0;

    // Tell Swift to start buffering audio for Whisper
    this.sendCommand("start-capture");

    // Timeout: if no final transcript in 8 seconds, use what we have
    if (this.commandTimeout) clearTimeout(this.commandTimeout);
    this.commandTimeout = setTimeout(() => {
      if (this.state === "command-listening") {
        // Stop audio capture — Swift will emit command_audio event
        this.sendCommand("stop-capture");
        // Fall back to Apple transcript if no audio file arrives
        if (this.commandBuffer.trim()) {
          this.fallbackCommand = this.commandBuffer.trim();
        }
        this.state = "wake-listening";
        this.commandBuffer = "";
      }
    }, 8000);
  }

  /** Go back to wake word listening */
  resumeWakeListening() {
    this.state = "wake-listening";
    this.commandBuffer = "";
    if (this.commandTimeout) {
      clearTimeout(this.commandTimeout);
      this.commandTimeout = null;
    }
  }

  private async ensureBinary() {
    if (existsSync(this.binaryPath)) {
      console.log("Wake listener binary found at:", this.binaryPath);
      return;
    }

    console.log("Compiling wake listener...");
    const compile = Bun.spawn([
      "swiftc",
      "-O",
      "-o", this.binaryPath,
      this.sourcePath,
      "-framework", "Speech",
      "-framework", "AVFoundation",
    ], {
      stdout: "pipe",
      stderr: "pipe",
    });

    const stderr = await new Response(compile.stderr).text();
    await compile.exited;

    if (compile.exitCode !== 0) {
      console.error("Failed to compile wake listener:", stderr);
      throw new Error(`Swift compilation failed: ${stderr}`);
    }

    console.log("Wake listener compiled successfully");
  }

  private spawnListener() {
    console.log("Starting wake word listener...");

    this.proc = Bun.spawn([this.binaryPath], {
      stdout: "pipe",
      stderr: "pipe",
      stdin: "pipe",
    });

    this.state = "wake-listening";

    // Read stdout line by line
    this.readLines();

    // Handle process exit
    this.proc.exited.then((code) => {
      console.log(`Wake listener exited with code ${code}`);
      this.proc = null;

      // Auto-restart after a delay unless intentionally stopped
      if (this.state !== "idle") {
        console.log("Restarting wake listener in 2 seconds...");
        setTimeout(() => this.spawnListener(), 2000);
      }
    });
  }

  private async readLines() {
    if (!this.proc?.stdout) return;

    const reader = this.proc.stdout.getReader();
    const decoder = new TextDecoder();
    let buffer = "";

    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;

        buffer += decoder.decode(value, { stream: true });

        // Process complete lines
        let newlineIdx: number;
        while ((newlineIdx = buffer.indexOf("\n")) !== -1) {
          const line = buffer.slice(0, newlineIdx).trim();
          buffer = buffer.slice(newlineIdx + 1);

          if (line) {
            this.handleLine(line);
          }
        }
      }
    } catch (e) {
      // Process ended, reader closed
    }
  }

  private handleLine(line: string) {
    let event: { type: string; text?: string; message?: string; final?: boolean };
    try {
      event = JSON.parse(line);
    } catch {
      console.log("Wake listener:", line);
      return;
    }

    if (event.type === "command_audio") {
      // Audio file from Swift — send to Whisper for transcription
      console.log("Command audio captured:", event.path);
      this.callback({ type: "command_audio", path: event.path });
      this.fallbackCommand = "";
      return;
    }

    if (event.type === "status") {
      // Suppress duplicate status messages to avoid log spam
      if (event.message === this.lastStatusMessage) return;
      this.lastStatusMessage = event.message || "";

      console.log("Wake listener status:", event.message);
      if (event.message === "listening") {
        this.callback({ type: "status", message: "Listening for \"Hey John\"..." });
      }
      return;
    }

    if (event.type === "error") {
      console.error("Wake listener error:", event.message);
      this.callback({ type: "error", message: event.message || "Unknown error" });
      return;
    }

    if (event.type === "transcript") {
      const text = (event.text || "").toLowerCase().trim();

      if (this.state === "wake-listening") {
        // Check for sleep phrase
        for (const phrase of SLEEP_PHRASES) {
          if (text.includes(phrase)) {
            console.log("Sleep phrase detected in:", text);
            this.callback({ type: "sleep" });
            return;
          }
        }

        // Check for wake phrase
        for (const phrase of WAKE_PHRASES) {
          if (text.includes(phrase)) {
            console.log("Wake word detected in:", text);
            this.callback({ type: "wake" });
            // Don't immediately switch to command mode here — wait for the
            // caller to call listenForCommand() after handling the wake event
            return;
          }
        }
      } else if (this.state === "command-listening") {
        // In command mode — strip the wake phrase and capture the rest
        let commandText = event.text || "";

        // Remove any wake phrase prefix from the command
        const lower = commandText.toLowerCase();
        for (const phrase of WAKE_PHRASES) {
          const idx = lower.indexOf(phrase);
          if (idx !== -1) {
            commandText = commandText.slice(idx + phrase.length).trim();
          }
        }

        if (commandText.trim()) {
          this.commandBuffer = commandText.trim();
        }

        // If this is a final result, stop audio capture and wait for Whisper
        if (event.final && this.commandBuffer) {
          if (this.commandTimeout) {
            clearTimeout(this.commandTimeout);
            this.commandTimeout = null;
          }
          // Stop audio capture — Swift will emit command_audio with the WAV path
          this.fallbackCommand = this.commandBuffer;
          this.sendCommand("stop-capture");
          this.commandBuffer = "";
          // Don't change state here — caller will call resumeWakeListening()
          // The command_audio event will trigger Whisper transcription
          // If no audio file arrives within 2s, fall back to Apple transcript
          setTimeout(() => {
            if (this.fallbackCommand) {
              console.log("No audio file received, falling back to Apple transcript");
              this.callback({ type: "command", text: this.fallbackCommand });
              this.fallbackCommand = "";
            }
          }, 2000);
        }
      }
    }
  }
}
