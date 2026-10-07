//! Voice calls. The protocol library does the signalling, the encryption and
//! the audio codec; this module gives it the microphone and the speaker, and
//! tells the UI what state the call is in.
//!
//! The library speaks 16 kHz mono in frames of 960 samples (60 ms). Sound
//! devices run at their own rate and channel count, so both directions are
//! resampled here.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use serde_json::{json, Value};
use whatsapp_rust::prelude::*;
use whatsapp_rust::voip::{CallEvent, CallHandle, VideoFrame, VideoUpgradeToken};
use whatsapp_rust::wacore::types::call::VideoState;
use whatsapp_rust::wacore::types::call::IncomingCall;

use crate::account::{Account, Request};

/// Where the app's camera frames go while a call has video: complete H.264
/// access units (Annex B), one per item. The library never touches pixels;
/// capture, encoding, decoding and display belong to each platform's app.
static CAMERA: Mutex<Option<async_channel::Sender<Vec<u8>>>> = Mutex::new(None);

/// Called by the app with each encoded camera frame (`WAVideoSend`).
pub(crate) fn camera_frame(data: Vec<u8>) {
    if let Some(camera) = CAMERA.lock().unwrap().as_ref() {
        // A full queue means the call cannot keep up: drop the frame, never block the encoder.
        let _ = camera.try_send(data);
    }
}

/// The two ends the library wants for video. Frames from the other side are
/// handed to `screen` (the app's `WAVideoSetSink` callback).
fn video_endpoints(rt: &tokio::runtime::Handle, screen: Arc<dyn Fn(&[u8], bool) + Send + Sync>) -> (async_channel::Receiver<Vec<u8>>, async_channel::Sender<VideoFrame>) {
    let (camera_tx, camera_rx) = async_channel::bounded::<Vec<u8>>(4);
    let (screen_tx, screen_rx) = async_channel::bounded::<VideoFrame>(8);
    *CAMERA.lock().unwrap() = Some(camera_tx);
    rt.spawn(async move {
        while let Ok(frame) = screen_rx.recv().await {
            screen(&frame.data, frame.keyframe);
        }
    });
    (camera_rx, screen_tx)
}

const RATE: f64 = 16_000.0;
const FRAME: usize = 960;

/// The call in progress, if any. One at a time.
pub(crate) struct ActiveCall {
    pub id: String,
    pub peer: String,
    handle: CallHandle,
    /// Dropping this stops the sound devices.
    _audio: Audio,
    /// The other side asked to turn the call into a video call.
    video_request: Arc<Mutex<Option<VideoUpgradeToken>>>,
}

/// The microphone and speaker of a call. The streams live on their own
/// thread (on macOS they may not move between threads) until this is dropped.
struct Audio {
    stop: Arc<AtomicBool>,
}

impl Drop for Audio {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
    }
}

type Mic = async_channel::Receiver<Vec<i16>>;
type Speaker = async_channel::Sender<Vec<i16>>;

impl Audio {
    /// Opens the default microphone and speaker. Returns the two channel ends
    /// the library wants, and a flag that turns true once the other side's
    /// voice has arrived (the sign that the call is really connected).
    fn open(rt: &tokio::runtime::Handle) -> Result<(Audio, Mic, Speaker, Arc<AtomicBool>), String> {
        let (mic_tx, mic_rx) = async_channel::bounded::<Vec<i16>>(3);
        let (speaker_tx, speaker_rx) = async_channel::bounded::<Vec<i16>>(8);
        let stop = Arc::new(AtomicBool::new(false));
        let heard = Arc::new(AtomicBool::new(false));
        // What the speaker has yet to play, at 16 kHz.
        let pending: Arc<Mutex<VecDeque<i16>>> = Arc::new(Mutex::new(VecDeque::new()));

        let (queue, heard_flag) = (pending.clone(), heard.clone());
        rt.spawn(async move {
            while let Ok(frame) = speaker_rx.recv().await {
                heard_flag.store(true, Ordering::Relaxed);
                let mut queue = queue.lock().unwrap();
                queue.extend(frame);
                // Never more than a third of a second behind: old sound is dropped, not delayed.
                let excess = queue.len().saturating_sub(RATE as usize / 3);
                queue.drain(..excess);
            }
        });

        let (ready_tx, ready_rx) = std::sync::mpsc::channel::<Result<(), String>>();
        let stopping = stop.clone();
        std::thread::Builder::new()
            .name("zen-call-audio".into())
            .spawn(move || {
                let streams = (|| -> Result<(cpal::Stream, cpal::Stream), String> {
                    let host = cpal::default_host();
                    let input = host.default_input_device().ok_or("No microphone was found")?;
                    let output = host.default_output_device().ok_or("No speaker was found")?;
                    let in_config = input.default_input_config().map_err(|e| e.to_string())?;
                    let out_config = output.default_output_config().map_err(|e| e.to_string())?;
                    let (in_rate, in_channels) = (in_config.sample_rate() as f64, in_config.channels() as usize);
                    let (out_rate, out_channels) = (out_config.sample_rate() as f64, out_config.channels() as usize);

                    // Microphone: mix to mono, resample down to 16 kHz, cut into frames.
                    let mut down = Resampler::new(in_rate, RATE);
                    let mut frame = Vec::with_capacity(FRAME);
                    let capture = input
                        .build_input_stream(
                            in_config.into(),
                            move |data: &[f32], _: &cpal::InputCallbackInfo| {
                                for chunk in data.chunks(in_channels) {
                                    let mono = chunk.iter().sum::<f32>() / in_channels as f32;
                                    down.push(mono, |sample| {
                                        frame.push((sample.clamp(-1.0, 1.0) * 32767.0) as i16);
                                        if frame.len() == FRAME {
                                            // A full queue means the call is not keeping up; drop, never block.
                                            let _ = mic_tx.try_send(std::mem::replace(&mut frame, Vec::with_capacity(FRAME)));
                                        }
                                    });
                                }
                            },
                            |_| {},
                            None,
                        )
                        .map_err(|e| e.to_string())?;

                    // Speaker: resample up from 16 kHz and copy to every channel.
                    let mut up = Resampler::new(RATE, out_rate);
                    let mut ready: VecDeque<f32> = VecDeque::new();
                    let playback = output
                        .build_output_stream(
                            out_config.into(),
                            move |data: &mut [f32], _: &cpal::OutputCallbackInfo| {
                                let wanted = data.len() / out_channels;
                                if ready.len() < wanted {
                                    let mut queue = pending.lock().unwrap();
                                    while ready.len() < wanted {
                                        let Some(sample) = queue.pop_front() else { break };
                                        up.push(sample as f32 / 32768.0, |out| ready.push_back(out));
                                    }
                                }
                                for chunk in data.chunks_mut(out_channels) {
                                    // Nothing to play is silence, not a stall.
                                    chunk.fill(ready.pop_front().unwrap_or(0.0));
                                }
                            },
                            |_| {},
                            None,
                        )
                        .map_err(|e| e.to_string())?;
                    capture.play().map_err(|e| e.to_string())?;
                    playback.play().map_err(|e| e.to_string())?;
                    Ok((capture, playback))
                })();
                match streams {
                    Ok(streams) => {
                        let _ = ready_tx.send(Ok(()));
                        while !stopping.load(Ordering::Relaxed) {
                            std::thread::sleep(std::time::Duration::from_millis(100));
                        }
                        drop(streams);
                    }
                    Err(error) => {
                        let _ = ready_tx.send(Err(error));
                    }
                }
            })
            .map_err(|e| e.to_string())?;
        ready_rx.recv_timeout(std::time::Duration::from_secs(5)).map_err(|_| "The sound devices did not start".to_string())??;
        Ok((Audio { stop }, mic_rx, speaker_tx, heard))
    }
}

/// Changes the sample rate of a stream, a sample at a time, by linear
/// interpolation: enough for speech, and free of delay.
struct Resampler {
    /// Input samples per output sample.
    step: f64,
    /// Where the next output sample falls between `last` and the newest input.
    position: f64,
    last: f32,
}

impl Resampler {
    fn new(from: f64, to: f64) -> Resampler {
        Resampler { step: from / to, position: 0.0, last: 0.0 }
    }

    fn push(&mut self, sample: f32, mut out: impl FnMut(f32)) {
        while self.position < 1.0 {
            out(self.last + (sample - self.last) * self.position as f32);
            self.position += self.step;
        }
        self.position -= 1.0;
        self.last = sample;
    }
}

impl Account {
    fn call_event(&self, id: &str, peer: &str, state: &str, extra: Value) {
        let mut event = json!({"type": "call_state", "id": id, "jid": peer, "name": self.db.name_of(peer), "state": state});
        if let (Some(event), Some(extra)) = (event.as_object_mut(), extra.as_object()) {
            event.extend(extra.clone());
        }
        self.send(event);
    }

    /// Call commands: start, accept, end, mute.
    pub(crate) fn call_command(self: &Arc<Self>, r: &Request) -> Result<Value, String> {
        match r.cmd.as_str() {
            "call_start" => {
                if self.call.lock().unwrap().is_some() {
                    return Err("There is already a call in progress".into());
                }
                let client = self.client()?;
                let peer: Jid = r.jid.parse().map_err(|_| "bad chat id".to_string())?;
                if r.jid.ends_with("@g.us") {
                    return Err("Group calls are not available yet".into());
                }
                let (audio, mic, speaker, heard) = Audio::open(&self.rt)?;
                let call = client.voip();
                let mut builder = call.call(&peer).audio(mic, speaker);
                if r.video {
                    let (camera, screen) = video_endpoints(&self.rt, self.screen.clone());
                    builder = builder.video(camera, screen);
                }
                let handle = self.rt.block_on(builder.start()).map_err(|e| e.to_string())?;
                let id = handle.call_id().to_string();
                self.call_event(&id, &r.jid, "calling", json!({"incoming": false, "video": r.video}));
                let video_request = self.watch_call(handle.clone(), id.clone(), r.jid.clone(), heard);
                *self.call.lock().unwrap() = Some(ActiveCall { id: id.clone(), peer: r.jid.clone(), handle, _audio: audio, video_request });
                Ok(json!({"id": id}))
            }
            "call_accept" => {
                if self.call.lock().unwrap().is_some() {
                    return Err("There is already a call in progress".into());
                }
                let client = self.client()?;
                let incoming = self.ringing.lock().unwrap().remove(&r.id).ok_or("That call is no longer ringing")?;
                let peer = self.rt.block_on(self.pn(&incoming.from));
                let (audio, mic, speaker, heard) = Audio::open(&self.rt)?;
                let call = client.voip();
                let mut builder = call.accept(&incoming).audio(mic, speaker);
                if r.video {
                    let (camera, screen) = video_endpoints(&self.rt, self.screen.clone());
                    builder = builder.video(camera, screen);
                }
                let handle = self.rt.block_on(builder.start()).map_err(|e| e.to_string())?;
                self.call_event(&r.id, &peer, "connecting", json!({"incoming": true, "video": r.video}));
                let video_request = self.watch_call(handle.clone(), r.id.clone(), peer.clone(), heard);
                *self.call.lock().unwrap() = Some(ActiveCall { id: r.id.clone(), peer, handle, _audio: audio, video_request });
                Ok(Value::Null)
            }
            "call_video" => {
                // Turns our camera on or off during a call; turning it on also
                // answers the other side's request for video, if there is one.
                let Some((handle, id, peer, request)) = self.call.lock().unwrap().as_ref().map(|c| (c.handle.clone(), c.id.clone(), c.peer.clone(), c.video_request.lock().unwrap().take())) else {
                    return Err("There is no call in progress".into());
                };
                if r.on {
                    let (camera, screen) = video_endpoints(&self.rt, self.screen.clone());
                    self.rt
                        .block_on(async {
                            match request {
                                Some(token) => handle.accept_video(token, camera, screen).await,
                                None => handle.start_video(camera, screen).await,
                            }
                        })
                        .map_err(|e| e.to_string())?;
                } else {
                    *CAMERA.lock().unwrap() = None;
                    self.rt.block_on(handle.stop_video()).map_err(|e| e.to_string())?;
                }
                self.call_event(&id, &peer, "camera", json!({"on": r.on}));
                Ok(Value::Null)
            }
            "call_end" => {
                *CAMERA.lock().unwrap() = None;
                let call = self.call.lock().unwrap().take();
                if let Some(call) = call {
                    self.rt.block_on(call.handle.hangup());
                    self.call_event(&call.id, &call.peer, "ended", json!({}));
                }
                Ok(Value::Null)
            }
            "call_mute" => {
                if let Some(call) = self.call.lock().unwrap().as_ref() {
                    call.handle.set_muted(r.on);
                    self.call_event(&call.id, &call.peer, "muted", json!({"muted": r.on}));
                }
                Ok(Value::Null)
            }
            other => Err(format!("unknown call command {other}")),
        }
    }

    /// Follows a call until it is over: reports when the other side's voice
    /// first arrives, and lets go of the devices when the call ends, however
    /// it ends.
    fn watch_call(self: &Arc<Self>, handle: CallHandle, id: String, peer: String, heard: Arc<AtomicBool>) -> Arc<Mutex<Option<VideoUpgradeToken>>> {
        let me = self.clone();
        let video_request: Arc<Mutex<Option<VideoUpgradeToken>>> = Arc::new(Mutex::new(None));
        // What the other side does with its camera.
        let (events, video_me, video_id, video_peer, pending) = (handle.events(), self.clone(), id.clone(), peer.clone(), video_request.clone());
        let video_watcher = self.rt.spawn(async move {
            while let Ok(event) = events.recv().await {
                let CallEvent::VideoStateChanged { state, upgrade_token, .. } = event else { continue };
                match state {
                    VideoState::UpgradeRequest | VideoState::UpgradeRequestV2 => {
                        *pending.lock().unwrap() = upgrade_token;
                        video_me.call_event(&video_id, &video_peer, "video_request", json!({}));
                    }
                    VideoState::Enabled | VideoState::UpgradeAccept => video_me.call_event(&video_id, &video_peer, "remote_video", json!({"on": true})),
                    VideoState::Disabled | VideoState::Stopped | VideoState::Paused | VideoState::UpgradeCancel | VideoState::UpgradeCancelByTimeout => {
                        *pending.lock().unwrap() = None;
                        video_me.call_event(&video_id, &video_peer, "remote_video", json!({"on": false}));
                    }
                    _ => {}
                }
            }
        });
        let (connected_id, connected_peer, active) = (id.clone(), peer.clone(), heard);
        let connected = self.clone();
        let watcher = self.rt.spawn(async move {
            while !active.load(Ordering::Relaxed) {
                tokio::time::sleep(std::time::Duration::from_millis(100)).await;
            }
            connected.call_event(&connected_id, &connected_peer, "active", json!({}));
        });
        self.rt.spawn(async move {
            handle.wait_ended().await;
            watcher.abort();
            video_watcher.abort();
            *CAMERA.lock().unwrap() = None;
            // Still ours: the call ended on its own (the other side hung up, or it failed).
            let ours = {
                let mut call = me.call.lock().unwrap();
                let ours = call.as_ref().is_some_and(|c| c.id == id);
                if ours {
                    *call = None;
                }
                ours
            };
            if ours {
                me.call_event(&id, &peer, "ended", json!({}));
            }
        });
        video_request
    }

    /// An incoming call started ringing: remembered so it can be accepted.
    pub(crate) fn ringing_started(&self, id: &str, incoming: &IncomingCall) {
        self.ringing.lock().unwrap().insert(id.to_string(), incoming.clone());
    }

    /// A ringing call stopped (answered elsewhere, cancelled, missed).
    pub(crate) fn ringing_stopped(&self, id: &str, peer: &str) {
        if self.ringing.lock().unwrap().remove(id).is_some() {
            self.call_event(id, peer, "ended", json!({"missed": true}));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::Resampler;

    fn run(from: f64, to: f64, input: &[f32]) -> Vec<f32> {
        let mut resampler = Resampler::new(from, to);
        let mut out = Vec::new();
        for &sample in input {
            resampler.push(sample, |s| out.push(s));
        }
        out
    }

    #[test]
    fn keeps_the_duration() {
        let second = vec![0.0f32; 48_000];
        assert!((run(48_000.0, 16_000.0, &second).len() as i64 - 16_000).abs() <= 1);
        assert!((run(44_100.0, 16_000.0, &vec![0.0; 44_100]).len() as i64 - 16_000).abs() <= 1);
        assert!((run(16_000.0, 48_000.0, &vec![0.0; 16_000]).len() as i64 - 48_000).abs() <= 3);
    }

    #[test]
    fn keeps_a_tone() {
        // 440 Hz at 48 kHz, down to 16 kHz: the same wave, sampled more sparsely.
        let tone: Vec<f32> = (0..4800).map(|n| (n as f32 * 440.0 * std::f32::consts::TAU / 48_000.0).sin()).collect();
        let out = run(48_000.0, 16_000.0, &tone);
        for (n, sample) in out.iter().enumerate().skip(4) {
            // Linear interpolation lags by at most one input sample.
            let expected = ((n as f32 * 3.0 - 1.0) * 440.0 * std::f32::consts::TAU / 48_000.0).sin();
            assert!((sample - expected).abs() < 0.08, "sample {n}: {sample} vs {expected}");
        }
    }
}
