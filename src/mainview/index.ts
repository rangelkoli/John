import { Electroview } from "electrobun/view";
import type { JohnRPCType } from "../shared/types";

const rpc = Electroview.defineRPC<JohnRPCType>({
	handlers: {
		requests: {},
		messages: {},
	},
});

const electroview = new Electroview({ rpc });

type MessageRole = "user" | "assistant";

type AssistantState = {
	speechEnabled: boolean;
	recognitionActive: boolean;
	voicesLoaded: boolean;
	isExpanded: boolean;
};

type SpeechRecognitionCtor = new () => SpeechRecognition;

declare global {
	interface Window {
		webkitSpeechRecognition?: SpeechRecognitionCtor;
		SpeechRecognition?: SpeechRecognitionCtor;
	}
}

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

if (!appShell || !orbContainer || !conversation || !composer || !promptInput || !voiceButton || !toggleSpeechButton || !minimizeButton || !voiceStatus || !speechStatus) {
	throw new Error("Main assistant UI failed to initialize.");
}

const state: AssistantState = {
	speechEnabled: true,
	recognitionActive: false,
	voicesLoaded: false,
	isExpanded: false,
};

const SpeechRecognitionImpl = window.SpeechRecognition ?? window.webkitSpeechRecognition;
const recognition = SpeechRecognitionImpl ? new SpeechRecognitionImpl() : null;

if (recognition) {
	recognition.lang = "en-US";
	recognition.interimResults = false;
	recognition.maxAlternatives = 1;
}

addMessage("assistant", "Hello, I'm John. Ask me anything.");
syncSpeechButton();

window.speechSynthesis.onvoiceschanged = () => {
	state.voicesLoaded = true;
};

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
	if (!recognition) {
		addMessage("assistant", "Voice input is not available in this webview. You can still type your requests.");
		return;
	}

	if (state.recognitionActive) {
		recognition.stop();
		return;
	}

	recognition.start();
	state.recognitionActive = true;
	syncVoiceButton();
});

toggleSpeechButton.addEventListener("click", () => {
	state.speechEnabled = !state.speechEnabled;
	if (!state.speechEnabled) {
		window.speechSynthesis.cancel();
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

orbContainer.addEventListener("click", () => {
	if (!state.isExpanded) {
		expandUI();
	}
});

minimizeButton.addEventListener("click", () => {
	collapseUI();
});

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

if (recognition) {
	recognition.addEventListener("result", (event) => {
		const spokenPrompt = event.results[0]?.[0]?.transcript?.trim();
		if (!spokenPrompt) return;
		handlePrompt(spokenPrompt);
	});

	recognition.addEventListener("end", () => {
		state.recognitionActive = false;
		syncVoiceButton();
	});

	recognition.addEventListener("error", () => {
		state.recognitionActive = false;
		syncVoiceButton();
	});
}

async function handlePrompt(prompt: string) {
	if (!state.isExpanded) {
		expandUI();
		await sleep(300);
	}

	addMessage("user", prompt);
	await sleep(100);
	showThinking();

	try {
		console.log("Sending message to agent:", prompt);
		const result = await electroview.rpc.request.processMessage({ message: prompt });
		console.log("Agent result:", JSON.stringify(result));

		removeThinking();

		if (result.success && result.response) {
			addMessage("assistant", result.response);
			speak(result.response);
		} else {
			const errorMsg = "Sorry, I couldn't process that. Please make sure Ollama is running.";
			addMessage("assistant", errorMsg);
			speak(errorMsg);
		}
	} catch (error) {
		console.error("RPC error:", error);
		removeThinking();

		const errorMsg = "Sorry, I'm having trouble connecting to the AI agent.";
		addMessage("assistant", errorMsg);
		speak(errorMsg);
	}
}

function addMessage(role: MessageRole, content: string) {
	const article = document.createElement("article");
	article.className = `message ${role === "assistant" ? "message-assistant" : "message-user"}`;

	const meta = document.createElement("span");
	meta.className = "message-meta";
	meta.textContent = role === "assistant" ? "John" : "You";

	const body = document.createElement("p");
	body.textContent = content;
	body.style.margin = "0";

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

function speak(message: string) {
	if (!state.speechEnabled) return;

	window.speechSynthesis.cancel();
	const utterance = new SpeechSynthesisUtterance(message);
	utterance.rate = 1;
	utterance.pitch = 1.05;
	utterance.volume = 1;

	const selectedVoice = pickVoice();
	if (selectedVoice) utterance.voice = selectedVoice;

	window.speechSynthesis.speak(utterance);
}

function pickVoice() {
	const voices = window.speechSynthesis.getVoices();
	if (!voices.length) return null;

	const preferredVoiceNames = ["Samantha", "Karen", "Daniel", "Google US English"];
	return preferredVoiceNames
		.map((name) => voices.find((voice) => voice.name === name))
		.find(Boolean) ?? voices.find((voice) => voice.lang.startsWith("en")) ?? voices[0];
}

function syncVoiceButton() {
	if (state.recognitionActive) {
		voiceButton.classList.add("listening");
	} else {
		voiceButton.classList.remove("listening");
	}
}

function syncSpeechButton() {
	syncVoiceButton();
}
