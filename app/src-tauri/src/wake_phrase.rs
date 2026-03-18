use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::SampleFormat;
use once_cell::sync::OnceCell;
use std::collections::VecDeque;
use std::sync::mpsc;
use std::sync::Mutex;
use std::thread;
use std::time::Duration;
use tauri::{AppHandle, Manager};

const WAKE_PHRASE: &str = "hey john";
const SAMPLE_RATE: u32 = 16_000;
const CHUNK_SIZE: usize = 1_600;
const PRE_ROLL_SAMPLES: usize = SAMPLE_RATE as usize / 2;
const MIN_SEGMENT_SAMPLES: usize = SAMPLE_RATE as usize / 2;
const MAX_SEGMENT_SAMPLES: usize = SAMPLE_RATE as usize * 3;
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

fn finalize_segment(segment: &mut Vec<f32>) -> bool {
    if segment.len() < MIN_SEGMENT_SAMPLES || segment.len() > MAX_SEGMENT_SAMPLES {
        segment.clear();
        return false;
    }

    let transcript = match super::audio::transcribe_samples(segment, "john-wake-phrase") {
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

    let supported_configs = device
        .supported_input_configs()
        .map_err(|e| format!("Failed to inspect input configs: {e}"))?;

    let config_range = supported_configs
        .filter(|config| config.channels() <= 2)
        .find(|config| config.sample_format() == SampleFormat::F32)
        .ok_or_else(|| "No supported f32 microphone config found.".to_string())?;

    let config = config_range.with_sample_rate(cpal::SampleRate(SAMPLE_RATE));
    let stream_config: cpal::StreamConfig = config.into();

    let (audio_tx, audio_rx) = mpsc::channel::<f32>();
    let stream = device
        .build_input_stream(
            &stream_config,
            move |data: &[f32], _: &cpal::InputCallbackInfo| {
                for &sample in data {
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

    let mut pre_roll = VecDeque::with_capacity(PRE_ROLL_SAMPLES);
    let mut chunk = Vec::with_capacity(CHUNK_SIZE);
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

        if pre_roll.len() == PRE_ROLL_SAMPLES {
            pre_roll.pop_front();
        }
        pre_roll.push_back(sample);

        chunk.push(sample);
        if chunk.len() < CHUNK_SIZE {
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

            if silence_chunks >= SILENCE_CHUNKS_TO_END || segment.len() >= MAX_SEGMENT_SAMPLES {
                if finalize_segment(&mut segment) {
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
