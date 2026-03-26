import { BrowserWindow, BrowserView, Screen } from "electrobun/bun";
import { processUserMessage } from "./agent";
import type { JohnRPCType } from "../shared/types";

let mainWindow: BrowserWindow;
const display = Screen.getPrimaryDisplay();
const initialWidth = 100;
const initialHeight = 100;
const initialX = display.workArea.x + display.workArea.width - initialWidth;
const initialY = display.workArea.y;

const rpc = BrowserView.defineRPC<JohnRPCType>({
	maxRequestTime: 120_000, // 2 minutes — LLM calls can take a while
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
		messages: {},
	},
});

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
