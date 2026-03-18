// Prevents additional console window on Windows in release, DO NOT REMOVE!!
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod audio;
mod wake_phrase;

use std::io::{BufRead, BufReader};
use std::path::PathBuf;
use std::process::{Command as ProcessCommand, Stdio};
use std::str;
use tauri::{Manager, PhysicalPosition, Position};

const WINDOW_MARGIN: i32 = 16;

#[cfg(target_os = "macos")]
#[allow(deprecated)]
use cocoa::{
    appkit::{NSColor, NSWindow},
    base::{id, nil, NO},
};

fn position_top_right(window: &tauri::Window) {
    if let Ok(Some(monitor)) = window.current_monitor() {
        let monitor_size = monitor.size();
        let monitor_position = monitor.position();
        let scale_factor = monitor.scale_factor();
        let physical_margin = (WINDOW_MARGIN as f64 * scale_factor) as i32;

        if let Ok(window_size) = window.outer_size() {
            let x = monitor_position.x + monitor_size.width as i32
                - window_size.width as i32
                - physical_margin;
            let y = monitor_position.y + physical_margin;
            let _ = window.set_position(Position::Physical(PhysicalPosition { x, y }));
        }
    }
}

#[cfg(target_os = "macos")]
#[allow(deprecated)]
fn configure_transparent_window(window: &tauri::Window) {
    if let Ok(ns_window) = window.ns_window() {
        let ns_window = ns_window as id;

        unsafe {
            ns_window.setOpaque_(NO);
            ns_window.setBackgroundColor_(NSColor::clearColor(nil));
        }
    }
}

#[tauri::command]
fn sync_window_size(window: tauri::Window, width: f64, height: f64) {
    if let Ok(Some(monitor)) = window.current_monitor() {
        let monitor_size = monitor.size();
        let monitor_position = monitor.position();
        let scale_factor = monitor.scale_factor();
        let physical_margin = (WINDOW_MARGIN as f64 * scale_factor) as i32;
        let max_physical_height = monitor_size
            .height
            .saturating_sub((physical_margin.max(0) as u32) * 2);

        let physical_width = (width * scale_factor) as u32;
        let physical_height = ((height * scale_factor) as u32).min(max_physical_height);

        let x = monitor_position.x + monitor_size.width as i32
            - physical_width as i32
            - physical_margin;
        let y = monitor_position.y + physical_margin;

        let _ = window.set_size(tauri::Size::Physical(tauri::PhysicalSize {
            width: physical_width,
            height: physical_height,
        }));
        let _ = window.set_position(tauri::Position::Physical(tauri::PhysicalPosition { x, y }));
    }
}

#[tauri::command]
fn ask_deep_agent(question: String) -> Result<String, String> {
    if question.trim().is_empty() {
        return Err("Question cannot be empty.".to_string());
    }

    let script = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("agent")
        .join("deep_agent.py");
    let python = std::env::var("DEEP_AGENT_PYTHON").unwrap_or_else(|_| "python3".to_string());

    let output = ProcessCommand::new(python)
        .arg(script)
        .arg("--question")
        .arg(question)
        .output()
        .map_err(|err| format!("Failed to start agent process: {err}"))?;

    if !output.status.success() {
        let err = match str::from_utf8(&output.stderr) {
            Ok(stderr) if !stderr.trim().is_empty() => stderr.trim().to_string(),
            _ => "Agent process failed without stderr output.".to_string(),
        };
        return Err(err);
    }

    let response = match str::from_utf8(&output.stdout) {
        Ok(text) => text.trim().to_string(),
        Err(_) => return Err("Agent output was not valid UTF-8.".to_string()),
    };

    if response.is_empty() {
        Err("Agent returned an empty response.".to_string())
    } else {
        Ok(response)
    }
}

#[tauri::command]
fn ask_deep_agent_stream(app_handle: tauri::AppHandle, question: String) -> Result<(), String> {
    if question.trim().is_empty() {
        return Err("Question cannot be empty.".to_string());
    }

    let script = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("agent")
        .join("deep_agent.py");
    let python = std::env::var("DEEP_AGENT_PYTHON").unwrap_or_else(|_| "python3".to_string());

    let mut child = ProcessCommand::new(python)
        .arg(script)
        .arg("--question")
        .arg(&question)
        .arg("--stream")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|err| format!("Failed to start agent process: {err}"))?;

    let stdout = child.stdout.take().ok_or("Failed to capture stdout")?;
    let stderr = child.stderr.take().ok_or("Failed to capture stderr")?;

    let app_handle_clone = app_handle.clone();

    // Spawn a thread to handle streaming output
    std::thread::spawn(move || {
        let reader = BufReader::new(stdout);

        for line in reader.lines() {
            match line {
                Ok(line) if !line.trim().is_empty() => {
                    let _ = app_handle_clone.emit_all("agent-stream", line);
                }
                _ => break,
            }
        }
    });

    // Handle stderr and process completion in another thread
    std::thread::spawn(move || {
        let stderr_reader = BufReader::new(stderr);
        let mut stderr_output = String::new();

        for line in stderr_reader.lines() {
            if let Ok(line) = line {
                stderr_output.push_str(&line);
                stderr_output.push('\n');
            }
        }

        let status = child.wait();
        match status {
            Ok(s) if !s.success() => {
                let err = if !stderr_output.trim().is_empty() {
                    stderr_output.trim().to_string()
                } else {
                    "Agent process failed without stderr output.".to_string()
                };
                let _ = app_handle.emit_all("agent-stream-error", err);
            }
            Err(e) => {
                let _ = app_handle.emit_all(
                    "agent-stream-error",
                    format!("Failed to wait for agent: {e}"),
                );
            }
            _ => {}
        }
    });

    Ok(())
}

#[tauri::command]
fn start_voice_recording() -> Result<(), String> {
    audio::start_recording()
}

#[tauri::command]
fn stop_and_transcribe(app_handle: tauri::AppHandle) -> Result<String, String> {
    let temp_dir = app_handle
        .path_resolver()
        .app_cache_dir()
        .unwrap_or_else(std::env::temp_dir);
    std::fs::create_dir_all(&temp_dir).map_err(|e| format!("Failed to create temp dir: {e}"))?;

    let audio_path = temp_dir.join("recording.wav");
    let path_str = audio_path.to_str().ok_or("Invalid path")?;

    audio::stop_recording(path_str)?;
    let text = audio::transcribe_audio(path_str)?;

    let _ = std::fs::remove_file(path_str);

    Ok(text)
}

#[tauri::command]
fn resume_wake_phrase_listener() -> Result<(), String> {
    wake_phrase::resume()
}

#[tauri::command]
fn pause_wake_phrase_listener() -> Result<(), String> {
    wake_phrase::pause()
}

#[tauri::command]
fn reveal_path_in_file_manager(path: String) -> Result<(), String> {
    let trimmed = path.trim();
    if trimmed.is_empty() {
        return Err("Path cannot be empty.".to_string());
    }

    let resolved = std::fs::canonicalize(PathBuf::from(trimmed))
        .map_err(|err| format!("Failed to resolve path \"{trimmed}\": {err}"))?;

    #[cfg(target_os = "macos")]
    let status = if resolved.is_dir() {
        ProcessCommand::new("open")
            .arg(&resolved)
            .status()
            .map_err(|err| format!("Failed to open Finder: {err}"))?
    } else {
        ProcessCommand::new("open")
            .arg("-R")
            .arg(&resolved)
            .status()
            .map_err(|err| format!("Failed to reveal file in Finder: {err}"))?
    };

    #[cfg(target_os = "windows")]
    let status = {
        let mut command = ProcessCommand::new("explorer");
        if resolved.is_dir() {
            command.arg(&resolved);
        } else {
            command.arg("/select,").arg(&resolved);
        }

        command
            .status()
            .map_err(|err| format!("Failed to open File Explorer: {err}"))?
    };

    #[cfg(all(not(target_os = "macos"), not(target_os = "windows")))]
    let status = {
        let target = if resolved.is_dir() {
            resolved.clone()
        } else {
            resolved
                .parent()
                .map(PathBuf::from)
                .unwrap_or_else(|| resolved.clone())
        };

        ProcessCommand::new("xdg-open")
            .arg(target)
            .status()
            .map_err(|err| format!("Failed to open file manager: {err}"))?
    };

    if status.success() {
        Ok(())
    } else {
        Err("File manager exited unsuccessfully.".to_string())
    }
}

fn main() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![
            ask_deep_agent,
            ask_deep_agent_stream,
            start_voice_recording,
            stop_and_transcribe,
            resume_wake_phrase_listener,
            pause_wake_phrase_listener,
            reveal_path_in_file_manager,
            sync_window_size
        ])
        .setup(|app| {
            let app_handle = app.handle();

            #[cfg(target_os = "macos")]
            if let Some(window) = app_handle.get_window("main") {
                configure_transparent_window(&window);
            }

            wake_phrase::start(app_handle.clone())?;

            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
