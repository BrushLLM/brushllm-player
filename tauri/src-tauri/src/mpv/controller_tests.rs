use super::*;
use std::io::{BufRead, BufReader, Write};

fn no_events() -> StateSink {
    Arc::new(|_| {})
}
fn wait_for(mut condition: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(3);
    while !condition() {
        assert!(Instant::now() < deadline, "condition timed out");
        std::thread::sleep(Duration::from_millis(5));
    }
}

#[test]
fn typed_observers_and_string_end_file_reasons() {
    assert_eq!(OBSERVED.len(), 11);
    for (name, id) in OBSERVED {
        let command = json!(["observe_property", id, name]);
        assert!(command[1].is_u64());
    }
    let shared = Shared::new(8, no_events());
    assert!(shared.connected(&AtomicBool::new(false)));
    for reason in ["eof", "stop", "quit"] {
        shared.dispatch(json!({"event":"end-file", "reason":reason}));
        assert!(shared.snapshot().error.is_none());
        assert_eq!(shared.snapshot().end_file.unwrap().reason, reason);
    }
    shared.dispatch(json!({"event":"end-file", "reason":"error", "file_error":"loading failed"}));
    assert_eq!(shared.snapshot().error.as_deref(), Some("loading failed"));
    assert_eq!(
        shared.snapshot().end_file.unwrap().file_error.as_deref(),
        Some("loading failed")
    );
    shared.dispatch(json!({"event":"file-loaded"}));
    assert!(shared.snapshot().error.is_none());
}

#[test]
fn start_file_changes_media_epoch_within_one_connection() {
    let shared = Shared::new(7, no_events());
    shared.connected(&AtomicBool::new(false));
    shared.dispatch(json!({"event":"start-file"}));
    let first = shared.snapshot();
    shared.dispatch(json!({"event":"property-change","name":"duration","data":40}));
    assert_eq!(shared.snapshot().media_epoch, first.media_epoch);
    shared.dispatch(json!({"event":"start-file"}));
    let next = shared.snapshot();
    assert_eq!(next.generation, first.generation);
    assert_eq!(next.media_epoch, first.media_epoch + 1);
    assert_eq!(next.properties["duration"], Value::Null);
    assert!(serde_json::to_value(next)
        .unwrap()
        .get("mediaEpoch")
        .is_some());
}

#[test]
fn disconnected_and_old_generations_cannot_cross_request_maps() {
    let old = Shared::new(1, no_events());
    old.connected(&AtomicBool::new(false));
    let (old_reply, old_receiver) = mpsc::channel();
    old.inner.lock().pending.insert(1, old_reply);
    old.invalidate(None);
    assert!(old_receiver.recv().unwrap().is_err());
    let new = Shared::new(2, no_events());
    new.connected(&AtomicBool::new(false));
    let (new_reply, new_receiver) = mpsc::channel();
    new.inner.lock().pending.insert(1, new_reply);
    old.dispatch(json!({"request_id":1,"error":"success","data":"stale"}));
    old.dispatch(json!({"event":"property-change","name":"volume","data":15}));
    assert!(new_receiver.try_recv().is_err());
    assert!(old.snapshot().properties.is_empty());
    new.dispatch(json!({"request_id":1,"error":"success","data":"new"}));
    assert_eq!(new_receiver.recv().unwrap().unwrap(), json!("new"));
}

#[cfg(not(target_os = "windows"))]
fn fake_controller(transport: Transport) -> Arc<MpvController> {
    let controller = Arc::new(MpvController {
        child: Mutex::new(None),
        workers: Mutex::new(Workers::default()),
        shared: Arc::new(Shared::new(1, no_events())),
        request_id: AtomicU64::new(1),
        closing: AtomicBool::new(false),
        stop_workers: Arc::new(AtomicBool::new(false)),
        endpoint: String::new(),
        endpoint_dir: PathBuf::new(),
    });
    controller.attach(transport).unwrap();
    controller
}
#[cfg(not(target_os = "windows"))]
fn pair() -> (Arc<MpvController>, std::os::unix::net::UnixStream) {
    let (client, peer) = std::os::unix::net::UnixStream::pair().unwrap();
    peer.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
    (
        fake_controller(transport::from_stream(client).unwrap()),
        peer,
    )
}
#[cfg(not(target_os = "windows"))]
fn read_command(reader: &mut impl BufRead) -> Value {
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    serde_json::from_str(&line).unwrap()
}

#[cfg(not(target_os = "windows"))]
#[test]
fn reader_first_concurrent_requests_and_out_of_order_replies() {
    let (controller, peer) = pair();
    let server = std::thread::spawn(move || {
        let mut reader = BufReader::new(peer);
        let first = read_command(&mut reader);
        let second = read_command(&mut reader); // Requires writer to be free while first waits.
        for message in [second, first] {
            writeln!(reader.get_mut(), "{}", json!({
                "request_id":message["request_id"], "error":"success", "data":message["command"][1]
            })).unwrap();
        }
    });
    let a = controller.clone();
    let first = std::thread::spawn(move || a.send_command(&[json!("echo"), json!("first")]));
    let b = controller.clone();
    let second = std::thread::spawn(move || b.send_command(&[json!("echo"), json!("second")]));
    assert_eq!(first.join().unwrap().unwrap(), json!("first"));
    assert_eq!(second.join().unwrap().unwrap(), json!("second"));
    server.join().unwrap();
    assert!(controller.shared.inner.lock().pending.is_empty());
    controller.shutdown().unwrap();
}

#[cfg(not(target_os = "windows"))]
#[test]
fn missing_and_late_reply_timeout_does_not_satisfy_next_request() {
    let (controller, peer) = pair();
    let server = std::thread::spawn(move || {
        let mut reader = BufReader::new(peer);
        let missing = read_command(&mut reader);
        std::thread::sleep(Duration::from_millis(100));
        writeln!(
            reader.get_mut(),
            "{}",
            json!({"request_id":missing["request_id"],"error":"success","data":"late"})
        )
        .unwrap();
        let next = read_command(&mut reader);
        writeln!(
            reader.get_mut(),
            "{}",
            json!({"request_id":next["request_id"],"error":"success","data":"current"})
        )
        .unwrap();
    });
    assert!(controller
        .request_until(
            &[json!("ignored")],
            Instant::now() + Duration::from_millis(30)
        )
        .unwrap_err()
        .contains("timed out"));
    assert!(controller.shared.inner.lock().pending.is_empty());
    assert_eq!(
        controller.send_command(&[json!("next")]).unwrap(),
        json!("current")
    );
    server.join().unwrap();
    controller.shutdown().unwrap();
}

#[cfg(not(target_os = "windows"))]
#[test]
fn eof_resolves_all_pending_requests_and_invalidates_state() {
    let (controller, peer) = pair();
    let c = controller.clone();
    let request = std::thread::spawn(move || c.send_command(&[json!("silent")]));
    let mut reader = BufReader::new(peer);
    read_command(&mut reader);
    let start = Instant::now();
    drop(reader);
    assert!(request.join().unwrap().is_err());
    wait_for(|| !controller.snapshot().connected);
    assert!(start.elapsed() < Duration::from_secs(1));
    assert!(controller.shared.inner.lock().pending.is_empty());
    controller.shutdown().unwrap();
}

#[cfg(not(target_os = "windows"))]
#[test]
fn partial_json_survives_reader_poll_timeouts_and_command_errors_are_returned() {
    let (controller, peer) = pair();
    let server = std::thread::spawn(move || {
        let mut reader = BufReader::new(peer);
        let command = read_command(&mut reader);
        let reply = format!(
            "{}\n",
            json!({"request_id":command["request_id"],"error":"invalid parameter"})
        );
        let halfway = reply.len() / 2;
        reader
            .get_mut()
            .write_all(&reply.as_bytes()[..halfway])
            .unwrap();
        std::thread::sleep(Duration::from_millis(120));
        reader
            .get_mut()
            .write_all(&reply.as_bytes()[halfway..])
            .unwrap();
    });
    assert!(controller
        .send_command(&[json!("bad")])
        .unwrap_err()
        .contains("invalid parameter"));
    server.join().unwrap();
    controller.shutdown().unwrap();
}

#[cfg(not(target_os = "windows"))]
#[test]
fn stalled_socket_writer_and_silent_reader_shutdown_are_bounded() {
    let (controller, _silent_peer) = pair();
    let c = controller.clone();
    let request = std::thread::spawn(move || {
        c.request_until(
            &[json!("echo"), json!("x".repeat(4 * 1024 * 1024))],
            Instant::now() + Duration::from_secs(5),
        )
    });
    wait_for(|| !controller.shared.inner.lock().pending.is_empty());
    std::thread::sleep(Duration::from_millis(25));
    let start = Instant::now();
    controller.shutdown_for(Duration::from_millis(600)).unwrap();
    assert!(start.elapsed() < Duration::from_millis(800));
    assert!(request.join().unwrap().is_err());
    assert!(controller.workers.lock().threads.is_empty());
    controller.shutdown().unwrap();
}

#[cfg(not(target_os = "windows"))]
#[test]
fn force_kill_does_not_wait_for_writer_and_ignores_quit() {
    struct BlockedWriter;
    impl transport::DeadlineWriter for BlockedWriter {
        fn write_until(&mut self, _: &[u8], _: Instant) -> std::io::Result<()> {
            std::thread::sleep(Duration::from_millis(700));
            Ok(())
        }
    }
    let (stream, _peer) = std::os::unix::net::UnixStream::pair().unwrap();
    let mut transport = transport::from_stream(stream).unwrap();
    transport.writer = Box::new(BlockedWriter);
    let controller = fake_controller(transport);
    let child = Command::new("/bin/sleep").arg("20").spawn().unwrap();
    *controller.child.lock() = Some(child);
    let c = controller.clone();
    let request = std::thread::spawn(move || c.send_command(&[json!("blocked")]));
    wait_for(|| !controller.shared.inner.lock().pending.is_empty());
    std::thread::sleep(Duration::from_millis(20));
    let start = Instant::now();
    assert!(controller
        .shutdown_for(Duration::from_millis(350))
        .unwrap_err()
        .contains("deadline"));
    assert!(start.elapsed() < Duration::from_millis(550));
    assert!(
        controller.child.lock().is_none(),
        "child must be killed/reaped independently of writer"
    );
    assert!(request.join().unwrap().is_err());
    wait_for(|| {
        controller
            .workers
            .lock()
            .threads
            .iter()
            .all(JoinHandle::is_finished)
    });
    for thread in controller.workers.lock().threads.drain(..) {
        thread.join().unwrap();
    }
}

#[cfg(not(target_os = "windows"))]
struct TempMedia(PathBuf);
#[cfg(not(target_os = "windows"))]
impl TempMedia {
    fn new() -> Self {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path =
            PathBuf::from("/tmp").join(format!("brushllm-test-{}-{nonce}", std::process::id()));
        std::fs::create_dir(&path).unwrap();
        Self(path)
    }
    fn wav(&self, name: &str, seconds: u32) -> PathBuf {
        let samples = 8000 * seconds;
        let bytes = samples * 2;
        let mut wav = Vec::with_capacity(bytes as usize + 44);
        wav.extend(b"RIFF");
        wav.extend((bytes + 36).to_le_bytes());
        wav.extend(b"WAVEfmt ");
        wav.extend(16u32.to_le_bytes());
        wav.extend(1u16.to_le_bytes());
        wav.extend(1u16.to_le_bytes());
        wav.extend(8000u32.to_le_bytes());
        wav.extend(16000u32.to_le_bytes());
        wav.extend(2u16.to_le_bytes());
        wav.extend(16u16.to_le_bytes());
        wav.extend(b"data");
        wav.extend(bytes.to_le_bytes());
        wav.resize(bytes as usize + 44, 0);
        let path = self.0.join(name);
        std::fs::write(&path, wav).unwrap();
        path
    }
    fn config(&self) -> LaunchConfig {
        let binary = std::env::var_os("BRUSHPLAYER_TEST_MPV")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("bin/mpv"));
        assert!(
            binary.is_file(),
            "the supplied local mpv binary is required"
        );
        LaunchConfig {
            binary,
            isolation: Some(self.0.clone()),
            args: [
                "--no-config",
                "--load-scripts=no",
                "--vo=null",
                "--ao=null",
                "--idle=yes",
                "--terminal=no",
                "--save-position-on-quit=no",
            ]
            .into_iter()
            .map(str::to_owned)
            .collect(),
        }
    }
}
#[cfg(not(target_os = "windows"))]
impl Drop for TempMedia {
    fn drop(&mut self) {
        // Only this freshly-created synthetic fixture; never media/user paths.
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[cfg(not(target_os = "windows"))]
#[test]
fn real_isolated_mpv_subscriptions_playback_failures_eof_and_reconnect() {
    let temp = TempMedia::new();
    let long = temp.wav("synthetic.wav", 6);
    let short = temp.wav("short.wav", 1);
    let broken = temp.0.join("broken.wav");
    std::fs::write(&broken, b"not valid media").unwrap();
    let config = temp.config();
    let mut player = MpvPlayer::new(no_events());
    player.config = config;
    let initial = player.ready().unwrap();
    assert!(initial.ready);
    wait_for(|| player.snapshot().properties.len() == 11);
    assert_eq!(player.snapshot().properties["idle-active"], json!(true));
    for (name, value) in [("volume", "65"), ("speed", "1.25"), ("pause", "yes")] {
        player
            .command(&[json!("set_property"), json!(name), json!(value)], false)
            .unwrap();
    }
    player
        .command(
            &[
                json!("loadfile"),
                json!(long.to_string_lossy()),
                json!("replace"),
            ],
            true,
        )
        .unwrap();
    wait_for(|| {
        player
            .snapshot()
            .properties
            .get("duration")
            .and_then(Value::as_f64)
            .unwrap_or(0.)
            > 5.
    });
    let snapshot = player.snapshot();
    assert_eq!(snapshot.properties["volume"], json!(65.0));
    assert_eq!(snapshot.properties["speed"], json!(1.25));
    assert_eq!(snapshot.properties["pause"], json!(true));
    assert_eq!(snapshot.properties["playlist-count"], json!(1));
    assert_eq!(snapshot.properties["playlist-pos"], json!(0));
    assert!(!snapshot.properties["filename"].as_str().unwrap().is_empty());
    player
        .command(
            &[
                json!("loadfile"),
                json!(short.to_string_lossy()),
                json!("append"),
            ],
            false,
        )
        .unwrap();
    wait_for(|| player.snapshot().properties.get("playlist-count") == Some(&json!(2)));
    player
        .command(&[json!("seek"), json!(2), json!("absolute+exact")], false)
        .unwrap();
    wait_for(|| {
        player
            .snapshot()
            .properties
            .get("time-pos")
            .and_then(Value::as_f64)
            .unwrap_or(0.)
            >= 1.9
    });
    assert!(player
        .command(&[json!("command-that-does-not-exist")], false)
        .unwrap_err()
        .message
        .contains("mpv command failed"));
    assert!(player
        .command(
            &[json!("get_property"), json!("property-that-does-not-exist")],
            false
        )
        .unwrap_err()
        .message
        .contains("property"));
    player
        .command(&[json!("stop"), json!("keep-playlist")], false)
        .unwrap();
    wait_for(|| {
        player
            .snapshot()
            .end_file
            .as_ref()
            .map(|e| e.reason.as_str())
            == Some("stop")
    });
    assert!(player.snapshot().error.is_none());
    for file in [temp.0.join("does-not-exist.wav"), broken] {
        // loadfile acknowledgement means accepted, not successfully decoded.
        player
            .command(
                &[
                    json!("loadfile"),
                    json!(file.to_string_lossy()),
                    json!("replace"),
                ],
                true,
            )
            .unwrap();
        wait_for(|| {
            player
                .snapshot()
                .end_file
                .as_ref()
                .map(|e| e.reason.as_str())
                == Some("error")
        });
        let failure = player.snapshot();
        assert!(!failure.end_file.unwrap().file_error.unwrap().is_empty());
        assert!(failure.error.is_some());
        // Recover between the two failures so the next wait cannot accidentally
        // observe the previous file's error before start-file is dispatched.
        player
            .command(
                &[
                    json!("loadfile"),
                    json!(long.to_string_lossy()),
                    json!("replace"),
                ],
                true,
            )
            .unwrap();
        wait_for(|| {
            let state = player.snapshot();
            state.end_file.is_none()
                && state
                    .properties
                    .get("duration")
                    .and_then(Value::as_f64)
                    .unwrap_or(0.)
                    > 5.
        });
        assert!(player.snapshot().error.is_none());
    }
    player
        .command(&[json!("set_property"), json!("pause"), json!("no")], false)
        .unwrap();
    player
        .command(&[json!("set_property"), json!("speed"), json!(4)], false)
        .unwrap();
    player
        .command(
            &[
                json!("loadfile"),
                json!(short.to_string_lossy()),
                json!("replace"),
            ],
            true,
        )
        .unwrap();
    wait_for(|| {
        player
            .snapshot()
            .end_file
            .as_ref()
            .map(|e| e.reason.as_str())
            == Some("eof")
    });
    assert!(player.snapshot().error.is_none());
    let old = player.current.lock().clone().unwrap();
    let old_endpoint = old.endpoint.clone();
    // Closing only IPC must invalidate, then next open must terminate the idle
    // child and rebuild instead of writing the disconnected transport.
    old.workers.lock().cancel.as_ref().unwrap().cancel();
    wait_for(|| !player.snapshot().connected);
    assert!(player
        .command(&[json!("cycle"), json!("pause")], false)
        .is_err());
    let loaded = player
        .command(
            &[
                json!("loadfile"),
                json!(long.to_string_lossy()),
                json!("replace"),
            ],
            true,
        )
        .unwrap();
    assert!(loaded.generation > initial.generation);
    assert!(old.child.lock().is_none());
    assert!(!PathBuf::from(&old_endpoint).exists());
    old.shared
        .dispatch(json!({"event":"property-change","name":"volume","data":1}));
    assert_ne!(player.snapshot().properties.get("volume"), Some(&json!(1)));
    // Simulate mpv window/q termination and reopen again.
    let current = player.current.lock().clone().unwrap();
    let _ = current.send_command(&[json!("quit")]);
    wait_for(|| !player.snapshot().connected);
    let restarted = player
        .command(
            &[
                json!("loadfile"),
                json!(long.to_string_lossy()),
                json!("replace"),
            ],
            true,
        )
        .unwrap();
    assert!(restarted.generation > loaded.generation);
    let final_controller = player.current.lock().clone().unwrap();
    let endpoint = final_controller.endpoint.clone();
    let start = Instant::now();
    player.shutdown().unwrap();
    assert!(start.elapsed() < Duration::from_secs(2));
    assert!(final_controller.child.lock().is_none());
    assert!(final_controller.workers.lock().threads.is_empty());
    assert!(!PathBuf::from(endpoint).exists());
    assert!(player.ready().is_err());
}

#[cfg(not(target_os = "windows"))]
#[test]
fn startup_exit_and_readiness_failures_do_not_leak_processes() {
    let temp = TempMedia::new();
    let controller = MpvController::spawn(1, no_events(), &temp.config()).unwrap();
    // Exit can kill a child before reader/IPC initialization completes.
    controller.shutdown_for(Duration::from_millis(600)).unwrap();
    assert!(controller.child.lock().is_none());
    assert!(controller.initialize(Duration::from_millis(200)).is_err());
    let invalid = LaunchConfig {
        binary: PathBuf::from("/bin/sleep"),
        args: vec!["10".into()],
        isolation: Some(temp.0.clone()),
    };
    let controller = MpvController::spawn(2, no_events(), &invalid).unwrap();
    assert!(controller.initialize(Duration::from_millis(200)).is_err());
    controller.shutdown().unwrap();
    assert!(controller.child.lock().is_none());
    assert!(!controller.endpoint_dir.exists());
}
