import { BrowserWindow, BrowserView, Screen } from "electrobun/bun";
import { processUserMessage, streamUserMessage } from "./agent";
import type { JohnRPCType } from "../shared/types";

import { readFileSync, unlinkSync } from "node:fs";

const display = Screen.getPrimaryDisplay();
const DAEMON_PORT = process.env.JOHN_DAEMON_PORT;
const DAEMON_URL = DAEMON_PORT ? `http://127.0.0.1:${DAEMON_PORT}` : null;

// ─── Whisper STT ───

async function transcribeWithWhisper(audioPath: string): Promise<string> {
	const apiKey = process.env.OPENAI_API_KEY;
	if (!apiKey) {
		throw new Error("OPENAI_API_KEY is not set");
	}

	const audioData = readFileSync(audioPath);
	const formData = new FormData();
	formData.append("file", new Blob([audioData], { type: "audio/wav" }), "command.wav");
	formData.append("model", "whisper-1");
	formData.append("language", "en");

	const response = await fetch("https://api.openai.com/v1/audio/transcriptions", {
		method: "POST",
		headers: {
			"Authorization": `Bearer ${apiKey}`,
		},
		body: formData,
	});

	// Clean up temp file
	try { unlinkSync(audioPath); } catch {}

	if (!response.ok) {
		const errBody = await response.text();
		throw new Error(`Whisper API error ${response.status}: ${errBody}`);
	}

	const result = await response.json() as { text: string };
	return result.text.trim();
}

// ─── RPC ───

const rpc = BrowserView.defineRPC<JohnRPCType>({
	maxRequestTime: 120_000,
	handlers: {
		requests: {
			processMessage: async ({ message, provider }) => {
				try {
					const response = await streamUserMessage(
						message,
						(chunk) => rpc.send.streamChunk({ text: chunk }),
						provider
					);
					rpc.send.streamEnd({});
					console.log(`Agent response (${provider}):`, response);
					return { success: true, response: String(response || ""), error: "" };
				} catch (error) {
					console.error("Agent error:", error);
					const errorMessage = error instanceof Error ? error.message : String(error);
					rpc.send.streamError({ error: errorMessage });
					return { success: false, response: "", error: errorMessage };
				}
			},
			resizeWindow: async ({ width, height }) => {
				if (mainWindow) {
					const newX = display.workArea.x + display.workArea.width - width;
					const newY = display.workArea.y;
					mainWindow.setSize(width, height);
					mainWindow.setPosition(newX, newY);
				}
			},
			generateSpeech: async ({ text }) => {
				const apiKey = process.env.OPENAI_API_KEY;
				if (!apiKey) {
					return { success: false, audioBase64: "", error: "OPENAI_API_KEY is not set. Add it to your .env file." };
				}
				try {
					const response = await fetch("https://api.openai.com/v1/audio/speech", {
						method: "POST",
						headers: {
							"Authorization": `Bearer ${apiKey}`,
							"Content-Type": "application/json",
						},
						body: JSON.stringify({
							model: "gpt-4o-mini-tts",
							voice: "ballad",
							input: text,
							response_format: "mp3",
						}),
					});
					if (!response.ok) {
						const errBody = await response.text();
						console.error("OpenAI TTS error:", response.status, errBody);
						return { success: false, audioBase64: "", error: `TTS API error: ${response.status}` };
					}
					const arrayBuf = await response.arrayBuffer();
					const audioBase64 = Buffer.from(arrayBuf).toString("base64");
					return { success: true, audioBase64, error: "" };
				} catch (error) {
					console.error("TTS error:", error);
					const msg = error instanceof Error ? error.message : String(error);
					return { success: false, audioBase64: "", error: msg };
				}
			},
		},
		messages: {
			commandHandled: () => {
				console.log("Command handled");
				if (DAEMON_URL) {
					fetch(`${DAEMON_URL}/command-handled`).catch(() => {});
				} else if (standaloneWakeListener) {
					standaloneWakeListener.resumeWakeListening();
				}
			},
		},
	},
});

// ─── Window ───

const mainWindow = new BrowserWindow({
	title: "John Assistant",
	url: "views://mainview/index.html",
	frame: {
		width: 100,
		height: 100,
		x: display.workArea.x + display.workArea.width - 100,
		y: display.workArea.y,
	},
	titleBarStyle: "hidden",
	transparent: true,
	rpc,
});

mainWindow.setAlwaysOnTop(true);
mainWindow.setVisibleOnAllWorkspaces(true);

// ─── Daemon mode: poll for wake events ───

let standaloneWakeListener: any = null;

if (DAEMON_URL) {
	// Signal readiness and get pending events
	(async () => {
		try {
			const res = await fetch(`${DAEMON_URL}/ready`);
			const events: Array<{ type: string; data?: string }> = await res.json();
			for (const event of events) {
				dispatchDaemonEvent(event);
			}
		} catch (err) {
			console.error("Failed to connect to daemon:", err);
		}

		// Poll for new events every 200ms
		setInterval(async () => {
			try {
				const res = await fetch(`${DAEMON_URL}/poll`);
				const events: Array<{ type: string; data?: string }> = await res.json();
				for (const event of events) {
					dispatchDaemonEvent(event);
				}
			} catch {
				// Daemon may have stopped
			}
		}, 200);
	})();
} else {
	// Standalone mode — run wake listener in-process
	import("./wake-listener").then(({ WakeWordListener }) => {
		const wl = new WakeWordListener((event) => {
			switch (event.type) {
				case "wake":
					rpc.send.wakeWordDetected({});
					wl.listenForCommand();
					break;
				case "sleep":
					console.log("Sleep requested via voice");
					rpc.send.sleepRequested({});
					break;
				case "command":
					rpc.send.commandCaptured({ text: event.text });
					break;
				case "command_audio":
					// Transcribe with Whisper, then send as command
					transcribeWithWhisper(event.path).then((text) => {
						console.log("Whisper transcription:", text);
						if (text) rpc.send.commandCaptured({ text });
					}).catch((err) => {
						console.error("Whisper transcription failed:", err);
						// Apple transcript fallback is handled by wake-listener timeout
					});
					break;
				case "status":
					rpc.send.wakeStatus({ message: event.message });
					break;
				case "error":
					console.error("Wake listener error:", event.message);
					break;
			}
		});
		standaloneWakeListener = wl;
		wl.start().catch(console.error);
	});
}

function dispatchDaemonEvent(event: { type: string; data?: string }) {
	switch (event.type) {
		case "wake":
			rpc.send.wakeWordDetected({});
			break;
		case "sleep":
			rpc.send.sleepRequested({});
			break;
		case "command":
			if (event.data) rpc.send.commandCaptured({ text: event.data });
			break;
		case "status":
			if (event.data) rpc.send.wakeStatus({ message: event.data });
			break;
	}
}

console.log(DAEMON_URL
	? "John Assistant started (daemon mode)"
	: "John Assistant started (standalone mode)"
);
