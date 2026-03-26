import { BrowserWindow, BrowserView, Screen } from "electrobun/bun";
import { processUserMessage } from "./agent";
import { WakeWordListener } from "./wake-listener";
import type { JohnRPCType } from "../shared/types";

let mainWindow: BrowserWindow;
const display = Screen.getPrimaryDisplay();
const initialWidth = 100;
const initialHeight = 100;
const initialX = display.workArea.x + display.workArea.width - initialWidth;
const initialY = display.workArea.y;

const rpc = BrowserView.defineRPC<JohnRPCType>({
	maxRequestTime: 120_000,
	handlers: {
		requests: {
			processMessage: async ({ message, provider }) => {
				try {
					const response = await processUserMessage(message, provider);
					console.log(`Agent response (${provider}):`, response);
					return { success: true, response: String(response || ""), error: "" };
				} catch (error) {
					console.error("Agent error:", error);
					const errorMessage = error instanceof Error ? error.message : String(error);
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
		},
		messages: {
			// Webview tells us it's done speaking / handling a command
			commandHandled: () => {
				console.log("Command handled, resuming wake word listening");
				wakeListener.resumeWakeListening();
			},
		},
	},
});

// ─── Wake Word Listener ───

const wakeListener = new WakeWordListener((event) => {
	switch (event.type) {
		case "wake":
			console.log("Wake word detected! Activating...");
			// Tell the webview to expand and show listening state
			rpc.send.wakeWordDetected({});
			// Switch to command capture mode
			wakeListener.listenForCommand();
			break;

		case "command":
			console.log("Command captured:", event.text);
			// Send the captured command to the webview
			rpc.send.commandCaptured({ text: event.text });
			break;

		case "status":
			rpc.send.wakeStatus({ message: event.message });
			break;

		case "error":
			console.error("Wake listener error:", event.message);
			break;
	}
});

// Start the wake word listener
wakeListener.start().catch((err) => {
	console.error("Failed to start wake listener:", err);
	console.log("Wake word detection will not be available. You can still use the app manually.");
});

// ─── Window ───

mainWindow = new BrowserWindow({
	title: "John Assistant",
	url: "views://mainview/index.html",
	frame: {
		width: initialWidth,
		height: initialHeight,
		x: initialX,
		y: initialY,
	},
	titleBarStyle: "hidden",
	transparent: true,
	rpc,
});

mainWindow.setAlwaysOnTop(true);
mainWindow.setVisibleOnAllWorkspaces(true);

console.log("John Assistant app started!");
