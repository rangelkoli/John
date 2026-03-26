import type { RPCSchema } from "electrobun/bun";

export type AIProvider = "local" | "openrouter";

export type JohnRPCType = {
	bun: RPCSchema<{
		requests: {
			processMessage: { params: { message: string; provider: AIProvider }; response: { success: boolean; response: string; error: string } };
			resizeWindow: { params: { width: number; height: number }; response: void };
			generateSpeech: { params: { text: string }; response: { success: boolean; audioBase64: string; error: string } };
		};
		messages: {
			wakeWordDetected: {};
			sleepRequested: {};
			commandCaptured: { text: string };
			wakeStatus: { message: string };
		};
	}>;
	webview: RPCSchema<{
		requests: {};
		messages: {
			commandHandled: {};
		};
	}>;
};
