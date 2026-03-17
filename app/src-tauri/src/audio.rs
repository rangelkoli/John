use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::SampleFormat;
use std::sync::mpsc;
use std::sync::Mutex;
use std::thread;

const SAMPLE_RATE: u32 = 16000;

static STOP_SENDER: Mutex<Option<mpsc::Sender<()>>> = Mutex::new(None);
static AUDIO_THREAD: Mutex<Option<thread::JoinHandle<Vec<f32>>>> = Mutex::new(None);

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
            None => return vec![],
        };

        let supported_configs = match device.supported_input_configs() {
            Ok(c) => c,
            Err(_) => return vec![],
        };

        let config_range = supported_configs
            .filter(|c| c.channels() <= 2)
            .find(|c| c.sample_format() == SampleFormat::F32)
            .or_else(|| {
                device
                    .supported_input_configs()
                    .ok()?
                    .find(|c| c.sample_format() == SampleFormat::F32)
            });

        let config_range = match config_range {
            Some(c) => c,
            None => return vec![],
        };

        let config = config_range.with_sample_rate(cpal::SampleRate(SAMPLE_RATE));
        let config_inner: cpal::StreamConfig = config.into();

        let stream = match device.build_input_stream(
            &config_inner,
            move |data: &[f32], _: &cpal::InputCallbackInfo| {
                for &sample in data {
                    let _ = audio_tx.send(sample);
                }
            },
            |err| eprintln!("Audio stream error: {err}"),
            None,
        ) {
            Ok(s) => s,
            Err(_) => return vec![],
        };

        if stream.play().is_err() {
            return vec![];
        }

        let _ = stop_rx.recv();

        drop(stream);

        let mut samples = Vec::new();
        while let Ok(sample) = audio_rx.try_recv() {
            samples.push(sample);
        }
        samples
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

    let samples = handle
        .ok_or_else(|| "No recording thread".to_string())?
        .join()
        .map_err(|_| "Recording thread panicked".to_string())?;

    if samples.is_empty() {
        return Err("No audio captured".to_string());
    }

    write_wav(output_path, &samples)?;
    Ok(())
}

fn write_wav(path: &str, samples: &[f32]) -> Result<(), String> {
    let spec = hound::WavSpec {
        channels: 1,
        sample_rate: SAMPLE_RATE,
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
