/**
 * Lightweight background daemon — runs only the wake word listener.
 * Memory usage: ~15-25MB (Bun runtime + Swift speech process).
 *
 * When the wake word is detected, spawns the full Electrobun app.
 * The app connects back via HTTP to receive events and notify completion.
 * After idle timeout, the app process is killed to free ~300MB.
 *
 * Usage: bun run src/daemon/index.ts
 */

import { WakeWordListener } from "../bun/wake-listener";

const PORT = 7377; // "JOHN" on phone keypad :)
const IDLE_TIMEOUT_MS = 60_000;

let appProc: ReturnType<typeof Bun.spawn> | null = null;
let appReady = false;
let pendingEvents: Array<{ type: string; data?: string }> = [];
let idleTimer: ReturnType<typeof setTimeout> | null = null;

// ─── IPC Server ───

const server = Bun.serve({
	port: PORT,
	hostname: "127.0.0.1",
	async fetch(req) {
		const url = new URL(req.url);

		// App signals it's ready — return any queued events
		if (url.pathname === "/ready") {
			appReady = true;
			const events = [...pendingEvents];
			pendingEvents = [];
			return Response.json(events);
		}

		// App signals command is done
		if (url.pathname === "/command-handled") {
			console.log("[daemon] Command handled, resuming wake listening");
			wakeListener.resumeWakeListening();
			resetIdleTimer();
			return new Response("ok");
		}

		// App sends keep-alive (user is interacting manually)
		if (url.pathname === "/keep-alive") {
			resetIdleTimer();
			return new Response("ok");
		}

		// Daemon pushes events to app via polling
		if (url.pathname === "/poll") {
			const events = [...pendingEvents];
			pendingEvents = [];
			return Response.json(events);
		}

		return new Response("not found", { status: 404 });
	},
});

console.log(`[daemon] IPC server on http://127.0.0.1:${PORT}`);

// ─── App Lifecycle ───

function resetIdleTimer() {
	if (idleTimer) clearTimeout(idleTimer);
	idleTimer = setTimeout(() => {
		console.log("[daemon] Idle timeout — killing app to free memory");
		killApp();
	}, IDLE_TIMEOUT_MS);
}

function killApp() {
	if (appProc) {
		try { appProc.kill(); } catch {}
		appProc = null;
	}
	appReady = false;
	pendingEvents = [];
	if (idleTimer) {
		clearTimeout(idleTimer);
		idleTimer = null;
	}
	console.log("[daemon] App killed, back to low-memory mode");
}

function ensureAppRunning() {
	if (appProc) return;

	console.log("[daemon] Launching Electrobun app...");
	appProc = Bun.spawn(["electrobun", "dev"], {
		cwd: import.meta.dir.replace("/src/daemon", ""),
		env: {
			...process.env,
			JOHN_DAEMON_PORT: String(PORT),
		},
		stdout: "inherit",
		stderr: "inherit",
	});

	appProc.exited.then((code) => {
		console.log(`[daemon] App exited (code ${code})`);
		appProc = null;
		appReady = false;
	});

	resetIdleTimer();
}

function queueEvent(event: { type: string; data?: string }) {
	pendingEvents.push(event);
}

// ─── Wake Word Listener ───

const wakeListener = new WakeWordListener((event) => {
	switch (event.type) {
		case "wake":
			console.log("[daemon] Wake word detected!");
			ensureAppRunning();
			queueEvent({ type: "wake" });
			wakeListener.listenForCommand();
			break;

		case "sleep":
			console.log("[daemon] Sleep requested");
			if (appReady) {
				queueEvent({ type: "sleep" });
			}
			break;

		case "command":
			console.log("[daemon] Command:", event.text);
			queueEvent({ type: "command", data: event.text });
			break;

		case "status":
			if (appReady) {
				queueEvent({ type: "status", data: event.message });
			}
			break;

		case "error":
			console.error("[daemon] Wake error:", event.message);
			break;
	}
});

wakeListener.start().catch((err) => {
	console.error("[daemon] Failed to start wake listener:", err);
});

console.log("[daemon] Running in low-memory mode (~15MB)");
console.log("[daemon] Say \"Hey John\" to activate");

// ─── Shutdown ───

process.on("SIGINT", () => {
	wakeListener.stop();
	killApp();
	server.stop();
	process.exit(0);
});

process.on("SIGTERM", () => {
	wakeListener.stop();
	killApp();
	server.stop();
	process.exit(0);
});
