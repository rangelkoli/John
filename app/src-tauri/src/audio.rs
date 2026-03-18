use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{SampleFormat, SupportedStreamConfigRange};
use std::sync::mpsc;
use std::sync::Mutex;
use std::thread;
use std::time::{SystemTime, UNIX_EPOCH};

pub const TARGET_SAMPLE_RATE: u32 = 16_000;

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

pub fn stop_recording(output_path: &str) -> Result<(), String> {
    let stop_tx = {
        let mut guard = STOP_SENDER.lock().unwrap();
        guard.take()
    };

    if stop_tx.is_none() {
        return Err("Not recording".to_string());
    }

    drop(stop_tx);

    let handle = {
        let mut guard = AUDIO_THREAD.lock().unwrap();
        guard.take()
    };

    let recorded_audio = handle
        .ok_or_else(|| "No recording thread".to_string())?
        .join()
        .map_err(|_| "Recording thread panicked".to_string())?;

    if recorded_audio.samples.is_empty() {
        return Err("No audio captured".to_string());
    }

    write_wav(output_path, &recorded_audio.samples, recorded_audio.sample_rate)?;
    Ok(())
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
