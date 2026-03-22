use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{SampleFormat, SupportedStreamConfigRange};
use std::collections::VecDeque;
use std::sync::mpsc;
use std::sync::Mutex;
use std::thread;
use std::time::Duration;
use std::time::{SystemTime, UNIX_EPOCH};



pub const TARGET_SAMPLE_RATE: u32 = 16_000;
const CAPTURE_CHUNK_MS: u32 = 80;
const CAPTURE_PRE_ROLL_MS: u32 = 250;
const CAPTURE_MIN_SPEECH_MS: u32 = 500;
const CAPTURE_MAX_SPEECH_MS: u32 = 12_000;
const CAPTURE_MAX_INITIAL_SILENCE_MS: u32 = 6_000;
const CAPTURE_SILENCE_CHUNKS_TO_END: usize = 12;
const CAPTURE_SPEECH_RMS_THRESHOLD: f32 = 0.012;

struct RecordedAudio {
    sample_rate: u32,
    samples: Vec<f32>,
}

static STOP_SENDER: Mutex<Option<mpsc::Sender<()>>> = Mutex::new(None);
static AUDIO_THREAD: Mutex<Option<thread::JoinHandle<RecordedAudio>>> = Mutex::new(None);

fn sample_rate_distance(config: &SupportedStreamConfigRange, preferred_sample_rate: u32) -> u32 {
    let min_sample_rate = config.min_sample_rate().0;
    let max_sample_rate = config.max_sample_rate().0;

    if preferred_sample_rate < min_sample_rate {
        min_sample_rate - preferred_sample_rate
    } else if preferred_sample_rate > max_sample_rate {
        preferred_sample_rate - max_sample_rate
    } else {
        0
    }
}

fn pick_sample_rate(config: &SupportedStreamConfigRange, preferred_sample_rate: u32) -> u32 {
    preferred_sample_rate.clamp(config.min_sample_rate().0, config.max_sample_rate().0)
}

fn samples_for_ms(sample_rate: u32, duration_ms: u32) -> usize {
    ((sample_rate as u64 * duration_ms as u64) / 1000).max(1) as usize
}

pub(crate) fn select_input_config(
    device: &cpal::Device,
    preferred_sample_rate: u32,
) -> Result<(cpal::StreamConfig, u32, usize), String> {
    let mut supported_configs = device
        .supported_input_configs()
        .map_err(|e| format!("Failed to inspect input configs: {e}"))?
        .filter(|config| config.channels() <= 2 && config.sample_format() == SampleFormat::F32)
        .collect::<Vec<_>>();

    supported_configs.sort_by_key(|config| {
        (
            if config.channels() == 1 { 0 } else { 1 },
            sample_rate_distance(config, preferred_sample_rate),
        )
    });

    let config_range = supported_configs
        .into_iter()
        .next()
        .ok_or_else(|| "No supported f32 microphone config found.".to_string())?;

    let sample_rate = pick_sample_rate(&config_range, preferred_sample_rate);
    let channels = config_range.channels() as usize;
    let config = config_range.with_sample_rate(cpal::SampleRate(sample_rate));

    Ok((config.into(), sample_rate, channels))
}

pub fn start_recording() -> Result<(), String> {
    let mut sender_guard = STOP_SENDER.lock().unwrap();
    if sender_guard.is_some() {
        return Err("Already recording".to_string());
    }

    let (stop_tx, stop_rx) = mpsc::channel::<()>();
    let (audio_tx, audio_rx) = mpsc::channel::<f32>();

    let handle = thread::spawn(move || {
        let host = cpal::default_host();
        let device = match host.default_input_device() {
            Some(d) => d,
            None => {
                return RecordedAudio {
                    sample_rate: TARGET_SAMPLE_RATE,
                    samples: vec![],
                };
            }
        };

        let (config_inner, sample_rate, channels) =
            match select_input_config(&device, TARGET_SAMPLE_RATE) {
                Ok(config) => config,
                Err(_) => {
                    return RecordedAudio {
                        sample_rate: TARGET_SAMPLE_RATE,
                        samples: vec![],
                    };
                }
            };

        let stream = match device.build_input_stream(
            &config_inner,
            move |data: &[f32], _: &cpal::InputCallbackInfo| {
                for frame in data.chunks(channels) {
                    let sample = frame.iter().copied().sum::<f32>() / frame.len() as f32;
                    let _ = audio_tx.send(sample);
                }
            },
            |err| eprintln!("Audio stream error: {err}"),
            None,
        ) {
            Ok(s) => s,
            Err(_) => {
                return RecordedAudio {
                    sample_rate,
                    samples: vec![],
                };
            }
        };

        if stream.play().is_err() {
            return RecordedAudio {
                sample_rate,
                samples: vec![],
            };
        }

        let _ = stop_rx.recv();

        drop(stream);

        let mut samples = Vec::new();
        while let Ok(sample) = audio_rx.try_recv() {
            samples.push(sample);
        }
        RecordedAudio {
            sample_rate,
            samples,
        }
    });

    *sender_guard = Some(stop_tx);
    let mut thread_guard = AUDIO_THREAD.lock().unwrap();
    *thread_guard = Some(handle);

    Ok(())
}

fn finish_recording_session() -> Result<Option<RecordedAudio>, String> {
    let stop_tx = {
        let mut guard = STOP_SENDER.lock().unwrap();
        guard.take()
    };

    let handle = {
        let mut guard = AUDIO_THREAD.lock().unwrap();
        guard.take()
    };

    if stop_tx.is_none() && handle.is_none() {
        return Ok(None);
    }

    drop(stop_tx);

    handle
        .map(|join_handle| {
            join_handle
                .join()
                .map_err(|_| "Recording thread panicked".to_string())
        })
        .transpose()
}

pub fn stop_recording(output_path: &str) -> Result<(), String> {
    let recorded_audio = finish_recording_session()?.ok_or_else(|| "Not recording".to_string())?;

    if recorded_audio.samples.is_empty() {
        return Err("No audio captured".to_string());
    }

    write_wav(
        output_path,
        &recorded_audio.samples,
        recorded_audio.sample_rate,
    )?;
    Ok(())
}

pub fn cancel_recording() -> Result<(), String> {
    let _ = finish_recording_session()?;
    Ok(())
}

pub fn capture_until_silence() -> Result<String, String> {
    if STOP_SENDER.lock().unwrap().is_some() {
        return Err("Already recording".to_string());
    }

    let host = cpal::default_host();
    let device = host
        .default_input_device()
        .ok_or_else(|| "No microphone input device found.".to_string())?;

    let (stream_config, sample_rate, channels) = select_input_config(&device, TARGET_SAMPLE_RATE)?;
    let chunk_size = samples_for_ms(sample_rate, CAPTURE_CHUNK_MS);
    let pre_roll_samples = samples_for_ms(sample_rate, CAPTURE_PRE_ROLL_MS);
    let min_speech_samples = samples_for_ms(sample_rate, CAPTURE_MIN_SPEECH_MS);
    let max_speech_samples = samples_for_ms(sample_rate, CAPTURE_MAX_SPEECH_MS);
    let max_initial_silence_chunks =
        (CAPTURE_MAX_INITIAL_SILENCE_MS / CAPTURE_CHUNK_MS).max(1) as usize;

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
            |err| eprintln!("Hands-free capture audio stream error: {err}"),
            None,
        )
        .map_err(|e| format!("Failed to start microphone stream: {e}"))?;

    stream
        .play()
        .map_err(|e| format!("Failed to play microphone stream: {e}"))?;

    let mut pre_roll = VecDeque::with_capacity(pre_roll_samples);
    let mut chunk = Vec::with_capacity(chunk_size);
    let mut captured = Vec::new();
    let mut heard_speech = false;
    let mut initial_silence_chunks = 0usize;
    let mut trailing_silence_chunks = 0usize;

    loop {
        let sample = match audio_rx.recv_timeout(Duration::from_millis(150)) {
            Ok(sample) => sample,
            Err(mpsc::RecvTimeoutError::Timeout) => continue,
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                return Err("Microphone stream disconnected.".to_string());
            }
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
        let is_speech = rms >= CAPTURE_SPEECH_RMS_THRESHOLD;

        if !heard_speech {
            if !is_speech {
                initial_silence_chunks += 1;
                chunk.clear();

                if initial_silence_chunks >= max_initial_silence_chunks {
                    return Err("I didn't hear anything. Try again.".to_string());
                }

                continue;
            }

            heard_speech = true;
            trailing_silence_chunks = 0;
            captured.extend(pre_roll.iter().copied());
            chunk.clear();
            continue;
        }

        captured.extend(chunk.iter().copied());
        chunk.clear();

        if is_speech {
            trailing_silence_chunks = 0;
        } else {
            trailing_silence_chunks += 1;
        }

        if captured.len() >= max_speech_samples {
            break;
        }

        if captured.len() >= min_speech_samples
            && trailing_silence_chunks >= CAPTURE_SILENCE_CHUNKS_TO_END
        {
            break;
        }
    }

    drop(stream);

    if captured.len() < min_speech_samples {
        return Err("I didn't catch enough speech to transcribe. Try again.".to_string());
    }

    let transcription = transcribe_samples(&captured, "john-voice-query", sample_rate)?;
    let trimmed = transcription.trim().to_string();
    if trimmed.is_empty() {
        return Err("I couldn't transcribe that. Try again.".to_string());
    }

    Ok(trimmed)
}

fn write_wav(path: &str, samples: &[f32], sample_rate: u32) -> Result<(), String> {
    let spec = hound::WavSpec {
        channels: 1,
        sample_rate,
        bits_per_sample: 16,
        sample_format: hound::SampleFormat::Int,
    };
    let mut writer =
        hound::WavWriter::create(path, spec).map_err(|e| format!("Failed to create WAV: {e}"))?;
    for &sample in samples {
        let s = (sample * i16::MAX as f32) as i16;
        writer
            .write_sample(s)
            .map_err(|e| format!("WAV write error: {e}"))?;
    }
    writer
        .finalize()
        .map_err(|e| format!("WAV finalize error: {e}"))?;
    Ok(())
}

pub fn transcribe_samples(
    samples: &[f32],
    file_prefix: &str,
    sample_rate: u32,
) -> Result<String, String> {
    if samples.is_empty() {
        return Err("No audio captured".to_string());
    }

    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|e| format!("Clock error: {e}"))?
        .as_millis();

    let audio_path = std::env::temp_dir().join(format!(
        "{file_prefix}-{}-{timestamp}.wav",
        std::process::id()
    ));
    let path_str = audio_path
        .to_str()
        .ok_or_else(|| "Invalid temp audio path".to_string())?;

    write_wav(path_str, samples, sample_rate)?;
    let transcription = transcribe_audio(path_str);
    let _ = std::fs::remove_file(path_str);

    transcription
}

pub fn transcribe_audio(audio_path: &str) -> Result<String, String> {
    let api_key =
        std::env::var("OPENAI_API_KEY").map_err(|_| "OPENAI_API_KEY not set".to_string())?;

    let rt = tokio::runtime::Runtime::new().map_err(|e| format!("Runtime error: {e}"))?;

    let audio_path = audio_path.to_string();
    rt.block_on(async move {
        let client = reqwest::Client::new();

        let file_bytes =
            std::fs::read(&audio_path).map_err(|e| format!("Failed to read audio: {e}"))?;

        let part = reqwest::multipart::Part::bytes(file_bytes)
            .file_name("recording.wav")
            .mime_str("audio/wav")
            .map_err(|e| format!("MIME error: {e}"))?;

        let form = reqwest::multipart::Form::new()
            .part("file", part)
            .text("model", "whisper-1")
            .text("language", "en");

        let response = client
            .post("https://api.openai.com/v1/audio/transcriptions")
            .bearer_auth(&api_key)
            .multipart(form)
            .send()
            .await
            .map_err(|e| format!("API request failed: {e}"))?;

        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().await.unwrap_or_default();
            return Err(format!("Whisper API error {status}: {body}"));
        }

        let body = response
            .text()
            .await
            .map_err(|e| format!("Failed to read response: {e}"))?;

        let json: serde_json::Value =
            serde_json::from_str(&body).map_err(|e| format!("Failed to parse response: {e}"))?;

        json.get("text")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
            .ok_or_else(|| "No text in response".to_string())
    })
}
