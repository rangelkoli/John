use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use once_cell::sync::OnceCell;
use std::collections::VecDeque;
use std::sync::mpsc;
use std::sync::Mutex;
use std::thread;
use std::time::Duration;
use tauri::{AppHandle, Manager};

const WAKE_PHRASE: &str = "hey john";
const CHUNK_MS: u32 = 100;
const PRE_ROLL_MS: u32 = 500;
const MIN_SEGMENT_MS: u32 = 500;
const MAX_SEGMENT_MS: u32 = 3_000;
const SILENCE_CHUNKS_TO_END: usize = 10;
const SPEECH_RMS_THRESHOLD: f32 = 0.015;

static APP_HANDLE: OnceCell<AppHandle> = OnceCell::new();
static LISTENER_STOP_SENDER: Mutex<Option<mpsc::Sender<()>>> = Mutex::new(None);
static LISTENER_THREAD: Mutex<Option<thread::JoinHandle<()>>> = Mutex::new(None);

fn contains_wake_phrase(text: &str) -> bool {
    let normalized = text
        .to_lowercase()
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || ch.is_ascii_whitespace() {
                ch
            } else {
                ' '
            }
        })
        .collect::<String>();

    normalized
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .contains(WAKE_PHRASE)
}

fn show_assistant() {
    let Some(app_handle) = APP_HANDLE.get() else {
        return;
    };

    if let Some(window) = app_handle.get_window("main") {
        super::position_top_right(&window);
        let _ = window.show();
        let _ = window.set_focus();
    }

    let _ = app_handle.emit_all("wake-phrase-detected", WAKE_PHRASE.to_string());
}

pub fn trigger() {
    show_assistant();
}

fn samples_for_ms(sample_rate: u32, duration_ms: u32) -> usize {
    ((sample_rate as u64 * duration_ms as u64) / 1000).max(1) as usize
}

fn finalize_segment(segment: &mut Vec<f32>, sample_rate: u32) -> bool {
    let min_segment_samples = samples_for_ms(sample_rate, MIN_SEGMENT_MS);
    let max_segment_samples = samples_for_ms(sample_rate, MAX_SEGMENT_MS);

    if segment.len() < min_segment_samples || segment.len() > max_segment_samples {
        segment.clear();
        return false;
    }

    let transcript =
        match super::audio::transcribe_samples(segment, "john-wake-phrase", sample_rate) {
        Ok(text) => text,
        Err(err) => {
            eprintln!("Wake phrase transcription failed: {err}");
            segment.clear();
            return false;
        }
    };

    segment.clear();

    if contains_wake_phrase(&transcript) {
        show_assistant();
        return true;
    }

    false
}

fn run_listener(stop_rx: mpsc::Receiver<()>) -> Result<(), String> {
    let host = cpal::default_host();
    let device = host
        .default_input_device()
        .ok_or_else(|| "No microphone input device found.".to_string())?;

    let (stream_config, sample_rate, channels) =
        super::audio::select_input_config(&device, super::audio::TARGET_SAMPLE_RATE)?;
    let chunk_size = samples_for_ms(sample_rate, CHUNK_MS);
    let pre_roll_samples = samples_for_ms(sample_rate, PRE_ROLL_MS);
    let max_segment_samples = samples_for_ms(sample_rate, MAX_SEGMENT_MS);

    let (audio_tx, audio_rx) = mpsc::channel::<f32>();
    let stream = device
        .build_input_stream(
            &stream_config,
            move |data: &[f32], _: &cpal::InputCallbackInfo| {
                for frame in data.chunks(channels) {
                    let sample = frame.iter().copied().sum::<f32>() / frame.len() as f32;
                    let _ = audio_tx.send(sample);
                }
            },
            |err| eprintln!("Wake phrase audio stream error: {err}"),
            None,
        )
        .map_err(|e| format!("Failed to start wake phrase stream: {e}"))?;

    stream
        .play()
        .map_err(|e| format!("Failed to play wake phrase stream: {e}"))?;

    let mut pre_roll = VecDeque::with_capacity(pre_roll_samples);
    let mut chunk = Vec::with_capacity(chunk_size);
    let mut segment = Vec::new();
    let mut capturing = false;
    let mut silence_chunks = 0usize;

    loop {
        if stop_rx.try_recv().is_ok() {
            break;
        }

        let sample = match audio_rx.recv_timeout(Duration::from_millis(100)) {
            Ok(sample) => sample,
            Err(mpsc::RecvTimeoutError::Timeout) => continue,
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        };

        if pre_roll.len() == pre_roll_samples {
            pre_roll.pop_front();
        }
        pre_roll.push_back(sample);

        chunk.push(sample);
        if chunk.len() < chunk_size {
            continue;
        }

        let rms =
            (chunk.iter().map(|sample| sample * sample).sum::<f32>() / chunk.len() as f32).sqrt();
        let is_speech = rms >= SPEECH_RMS_THRESHOLD;

        if !capturing && is_speech {
            capturing = true;
            segment.extend(pre_roll.iter().copied());
            silence_chunks = 0;
        }

        if capturing {
            segment.extend(chunk.iter().copied());

            if is_speech {
                silence_chunks = 0;
            } else {
                silence_chunks += 1;
            }

            if silence_chunks >= SILENCE_CHUNKS_TO_END || segment.len() >= max_segment_samples {
                if finalize_segment(&mut segment, sample_rate) {
                    break;
                }

                capturing = false;
                silence_chunks = 0;
            }
        }

        chunk.clear();
    }

    drop(stream);
    Ok(())
}

fn stop_listener() -> Result<(), String> {
    let stop_sender = {
        let mut guard = LISTENER_STOP_SENDER.lock().unwrap();
        guard.take()
    };

    if let Some(sender) = stop_sender {
        let _ = sender.send(());
    }

    let listener_thread = {
        let mut guard = LISTENER_THREAD.lock().unwrap();
        guard.take()
    };

    if let Some(handle) = listener_thread {
        handle
            .join()
            .map_err(|_| "Wake phrase thread panicked".to_string())?;
    }

    Ok(())
}

pub fn pause() -> Result<(), String> {
    stop_listener()
}

pub fn resume() -> Result<(), String> {
    stop_listener()?;

    let (stop_tx, stop_rx) = mpsc::channel::<()>();
    let handle = thread::spawn(move || {
        if let Err(err) = run_listener(stop_rx) {
            eprintln!("Wake phrase listener stopped: {err}");
        }
    });

    {
        let mut guard = LISTENER_STOP_SENDER.lock().unwrap();
        *guard = Some(stop_tx);
    }

    {
        let mut guard = LISTENER_THREAD.lock().unwrap();
        *guard = Some(handle);
    }

    Ok(())
}

pub fn start(app_handle: AppHandle) -> Result<(), String> {
    let _ = APP_HANDLE.set(app_handle);
    resume()
}
