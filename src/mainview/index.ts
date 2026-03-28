import { Electroview } from "electrobun/view";
import type { JohnRPCType, AIProvider } from "../shared/types";
import { marked } from "marked";

const rpc = Electroview.defineRPC<JohnRPCType>({
	maxRequestTime: 120_000,
	handlers: {
		requests: {},
		messages: {
			// Bun detected the wake word — expand UI, show listening state
			wakeWordDetected: () => {
				console.log("Wake word detected!");
				onWakeWordDetected();
			},

			// Bun detected sleep phrase — collapse UI
			sleepRequested: () => {
				console.log("Sleep requested!");
				onSleepRequested();
			},

			// Bun captured the spoken command — process it
			commandCaptured: ({ text }) => {
				console.log("Command captured:", text);
				onCommandCaptured(text);
			},

			// Status updates from the wake listener
			wakeStatus: ({ message }) => {
				updateVoiceStatus(message);
			},

			// Streaming chunks from the AI
			streamChunk: ({ text }) => {
				onStreamChunk(text);
			},
			streamEnd: () => {
				onStreamEnd();
			},
			streamError: ({ error }) => {
				onStreamError(error);
			},
		},
	},
});

const electroview = new Electroview({ rpc });

type MessageRole = "user" | "assistant";

type AssistantState = {
	speechEnabled: boolean;
	isExpanded: boolean;
	provider: AIProvider;
	waitingForCommand: boolean;
	processing: boolean;
};

const appShell = document.querySelector<HTMLElement>(".app-shell");
const orbContainer = document.querySelector<HTMLElement>(".orb-container");
const conversation = document.querySelector<HTMLDivElement>("#conversation");
const composer = document.querySelector<HTMLFormElement>("#composer");
const promptInput = document.querySelector<HTMLTextAreaElement>("#prompt-input");
const voiceButton = document.querySelector<HTMLButtonElement>("#voice-button");
const toggleSpeechButton = document.querySelector<HTMLButtonElement>("#toggle-speech");
const minimizeButton = document.querySelector<HTMLButtonElement>("#minimize-button");
const voiceStatus = document.querySelector<HTMLParagraphElement>("#voice-status");
const speechStatus = document.querySelector<HTMLParagraphElement>("#speech-status");
const suggestionButtons = document.querySelectorAll<HTMLButtonElement>(".suggestion-chip");
const providerButtons = document.querySelectorAll<HTMLButtonElement>(".provider-option");

if (!appShell || !orbContainer || !conversation || !composer || !promptInput || !voiceButton || !toggleSpeechButton || !minimizeButton || !voiceStatus || !speechStatus) {
	throw new Error("Main assistant UI failed to initialize.");
}

const state: AssistantState = {
	speechEnabled: true,
	isExpanded: false,
	provider: "openrouter",
	waitingForCommand: false,
	processing: false,
};

addMessage("assistant", "Hello, I'm John. Say \"Hey John\" or type anything.");
syncSpeechButton();

// ─── Streaming state ───

let streamingBody: HTMLDivElement | null = null;
let streamingContent = "";

function onStreamChunk(text: string) {
	streamingContent += text;

	// Create the message element on first chunk
	if (!streamingBody) {
		removeThinking();

		const article = document.createElement("article");
		article.className = "message message-assistant";
		article.id = "streaming-message";

		const meta = document.createElement("span");
		meta.className = "message-meta";
		meta.textContent = "John";

		streamingBody = document.createElement("div");
		streamingBody.className = "markdown-body";
		streamingBody.style.margin = "0";

		article.append(meta, streamingBody);
		conversation!.append(article);
	}

	streamingBody.innerHTML = marked.parse(streamingContent, { async: false }) as string;
	smoothScrollToBottom();
}

function onStreamEnd() {
	// Reset streaming state — the RPC response handler will speak the full response
	streamingBody = null;
	streamingContent = "";
}

function onStreamError(_error: string) {
	streamingBody = null;
	streamingContent = "";
}

// ─── Wake Word Activation (from Bun) ───

async function onWakeWordDetected() {
	if (state.processing) return;

	// Play activation chime
	playActivationSound();

	// Expand the UI
	if (!state.isExpanded) {
		await expandUI();
		await sleep(300);
	}

	// Show listening state
	state.waitingForCommand = true;
	orbContainer.classList.add("wake-active");
	voiceButton.classList.add("listening");
	updateVoiceStatus("Listening...");
}

async function onCommandCaptured(text: string) {
	state.waitingForCommand = false;
	voiceButton.classList.remove("listening");
	orbContainer.classList.remove("wake-active");
	updateVoiceStatus("");

	// Process the command
	await handlePrompt(text);
}

async function onSleepRequested() {
	// Stop any ongoing speech or processing
	stopSpeech();
	state.processing = false;
	state.waitingForCommand = false;
	orbContainer.classList.remove("wake-active");
	voiceButton.classList.remove("listening");
	updateVoiceStatus("");

	// Say goodbye then collapse
	speak("Goodbye!", () => {
		collapseUI();
	});
}

function playActivationSound() {
	try {
		const ctx = new AudioContext();
		const osc = ctx.createOscillator();
		const gain = ctx.createGain();
		osc.connect(gain);
		gain.connect(ctx.destination);
		osc.frequency.setValueAtTime(800, ctx.currentTime);
		osc.frequency.setValueAtTime(1200, ctx.currentTime + 0.08);
		gain.gain.setValueAtTime(0.15, ctx.currentTime);
		gain.gain.exponentialRampToValueAtTime(0.001, ctx.currentTime + 0.2);
		osc.start(ctx.currentTime);
		osc.stop(ctx.currentTime + 0.2);
	} catch {
		// Audio not available
	}
}

function updateVoiceStatus(text: string) {
	if (voiceStatus) voiceStatus.textContent = text;
}

// ─── Form & Button Handlers ───

composer.addEventListener("submit", (event) => {
	event.preventDefault();
	const prompt = promptInput.value.trim();
	if (!prompt) return;
	handlePrompt(prompt);
	promptInput.value = "";
	promptInput.style.height = "auto";
});

promptInput.addEventListener("input", () => {
	promptInput.style.height = "auto";
	promptInput.style.height = `${Math.min(promptInput.scrollHeight, 120)}px`;
});

promptInput.addEventListener("keydown", (event) => {
	if (event.key === "Enter" && !event.shiftKey) {
		event.preventDefault();
		composer.requestSubmit();
	}
});

voiceButton.addEventListener("click", () => {
	// Manual voice button — show a hint since wake word is always on
	addMessage("assistant", "Just say \"Hey John\" and then your question. I'm always listening!");
});

toggleSpeechButton.addEventListener("click", () => {
	state.speechEnabled = !state.speechEnabled;
	if (!state.speechEnabled) {
		stopSpeech();
	}
	syncSpeechButton();
});

suggestionButtons.forEach((button) => {
	button.addEventListener("click", () => {
		const prompt = button.dataset.prompt?.trim();
		if (!prompt) return;
		handlePrompt(prompt);
	});
});

providerButtons.forEach((button) => {
	button.addEventListener("click", () => {
		const provider = button.dataset.provider as AIProvider;
		if (!provider) return;
		state.provider = provider;
		providerButtons.forEach((b) => b.classList.remove("active"));
		button.classList.add("active");
	});
});

orbContainer.addEventListener("click", () => {
	if (!state.isExpanded) {
		expandUI();
	}
});

minimizeButton.addEventListener("click", () => {
	collapseUI();
});

// ─── UI expand / collapse ───

async function expandUI() {
	state.isExpanded = true;
	appShell.classList.remove("collapsed");
	appShell.classList.add("expanded");

	try {
		await electroview.rpc.request.resizeWindow({ width: 380, height: 600 });
	} catch (error) {
		console.error("Failed to resize window:", error);
	}
}

async function collapseUI() {
	state.isExpanded = false;

	appShell.classList.remove("expanded");
	appShell.classList.add("collapsing");

	await sleep(250);

	appShell.classList.remove("collapsing");
	appShell.classList.add("collapsed");

	try {
		await electroview.rpc.request.resizeWindow({ width: 100, height: 100 });
	} catch (error) {
		console.error("Failed to resize window:", error);
	}
}

// ─── Core prompt handler ───

async function handlePrompt(prompt: string) {
	state.processing = true;

	if (!state.isExpanded) {
		expandUI();
		await sleep(300);
	}

	addMessage("user", prompt);
	await sleep(100);
	showThinking();

	try {
		console.log("Sending message to agent:", prompt);
		const result = await electroview.rpc.request.processMessage({ message: prompt, provider: state.provider });
		console.log("Agent result:", JSON.stringify(result));

		removeThinking();

		if (result.success && result.response) {
			// If streaming already rendered the message, don't duplicate it
			const existing = document.getElementById("streaming-message");
			if (!existing) {
				addMessage("assistant", result.response);
			} else {
				existing.removeAttribute("id");
			}
			// Speak the response, then tell Bun we're done so it resumes wake listening
			speak(result.response, () => {
				state.processing = false;
				electroview.rpc.send.commandHandled({});
			});
		} else {
			const errorMsg = result.error?.includes("Ollama")
				? result.error
				: result.error || "Sorry, I couldn't process that. Please try again.";
			addMessage("assistant", errorMsg);
			speak(errorMsg, () => {
				state.processing = false;
				electroview.rpc.send.commandHandled({});
			});
		}
	} catch (error) {
		console.error("RPC error:", error);
		removeThinking();

		const detail = error instanceof Error ? error.message : String(error);
		const errorMsg = detail.includes("timed out")
			? "The request took too long. Please try again."
			: "Sorry, I'm having trouble connecting to the AI agent.";
		addMessage("assistant", errorMsg);
		speak(errorMsg, () => {
			state.processing = false;
			electroview.rpc.send.commandHandled({});
		});
	}
}

// ─── UI helpers ───

function addMessage(role: MessageRole, content: string) {
	const article = document.createElement("article");
	article.className = `message ${role === "assistant" ? "message-assistant" : "message-user"}`;

	const meta = document.createElement("span");
	meta.className = "message-meta";
	meta.textContent = role === "assistant" ? "John" : "You";

	const body = document.createElement("div");
	body.style.margin = "0";

	if (role === "assistant") {
		body.className = "markdown-body";
		body.innerHTML = marked.parse(content, { async: false }) as string;
	} else {
		body.textContent = content;
	}

	article.append(meta, body);
	conversation.append(article);
	smoothScrollToBottom();
}

function showThinking() {
	const thinking = document.createElement("div");
	thinking.className = "thinking-indicator";
	thinking.id = "thinking-indicator";

	for (let i = 0; i < 3; i++) {
		const dot = document.createElement("span");
		dot.className = "thinking-dot";
		thinking.append(dot);
	}

	conversation.append(thinking);
	smoothScrollToBottom();
}

function removeThinking() {
	const thinking = document.getElementById("thinking-indicator");
	if (thinking) {
		thinking.style.opacity = "0";
		thinking.style.transition = "opacity 0.15s ease";
		setTimeout(() => thinking.remove(), 150);
	}
}

function smoothScrollToBottom() {
	requestAnimationFrame(() => {
		conversation.scrollTo({ top: conversation.scrollHeight, behavior: "smooth" });
	});
}

function sleep(ms: number): Promise<void> {
	return new Promise((resolve) => setTimeout(resolve, ms));
}

let currentAudio: HTMLAudioElement | null = null;
let speechCancelToken = 0;

function stopSpeech() {
	speechCancelToken++;
	if (currentAudio) {
		currentAudio.pause();
		currentAudio.src = "";
		currentAudio = null;
	}
}

function splitIntoSentences(text: string): string[] {
	const sentences: string[] = [];
	const regex = /[^.!?]*[.!?]+[\s]?|[^.!?]+$/g;
	let match: RegExpExecArray | null;
	while ((match = regex.exec(text)) !== null) {
		const s = match[0].trim();
		if (s) sentences.push(s);
	}
	return sentences.length > 0 ? sentences : [text];
}

function speak(message: string, onDone?: () => void) {
	if (!state.speechEnabled) {
		onDone?.();
		return;
	}

	stopSpeech();
	const token = speechCancelToken;

	const sentences = splitIntoSentences(message);

	// Fire TTS requests for all sentences in parallel so later ones are ready when needed
	const ttsPromises = sentences.map((sentence) =>
		electroview.rpc.request.generateSpeech({ text: sentence }).catch(() => null)
	);

	function playChunk(index: number) {
		if (token !== speechCancelToken || !state.speechEnabled || index >= ttsPromises.length) {
			currentAudio = null;
			onDone?.();
			return;
		}

		ttsPromises[index].then((result) => {
			if (token !== speechCancelToken || !state.speechEnabled || !result || !result.success) {
				playChunk(index + 1);
				return;
			}

			const binaryStr = atob(result.audioBase64);
			const bytes = new Uint8Array(binaryStr.length);
			for (let i = 0; i < binaryStr.length; i++) {
				bytes[i] = binaryStr.charCodeAt(i);
			}
			const blob = new Blob([bytes], { type: "audio/mp3" });
			const url = URL.createObjectURL(blob);

			const audio = new Audio(url);
			currentAudio = audio;
			audio.addEventListener("ended", () => {
				URL.revokeObjectURL(url);
				playChunk(index + 1);
			});
			audio.addEventListener("error", () => {
				URL.revokeObjectURL(url);
				playChunk(index + 1);
			});
			audio.play();
		});
	}

	playChunk(0);
}

function syncVoiceButton() {
	if (state.waitingForCommand) {
		voiceButton.classList.add("listening");
	} else {
		voiceButton.classList.remove("listening");
	}
}

function syncSpeechButton() {
	syncVoiceButton();
}
