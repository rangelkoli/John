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
	handlers: {
		requests: {
			processMessage: async ({ message }) => {
				try {
					const response = await processUserMessage(message);
					console.log("Agent response:", response);
					return { success: true, response };
				} catch (error) {
					console.error("Agent error:", error);
					return { success: false, error: String(error) };
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
