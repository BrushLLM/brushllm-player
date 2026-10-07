//! Cancellable duplex IPC. No controller lock is held during I/O.
use std::io::{self, Read};
use std::sync::Arc;
use std::time::Instant;

pub(super) const IO_POLL: std::time::Duration = std::time::Duration::from_millis(50);

pub(super) trait DeadlineWriter: Send {
    fn write_until(&mut self, bytes: &[u8], deadline: Instant) -> io::Result<()>;
}

pub(super) trait Cancel: Send + Sync {
    fn cancel(&self);
}

pub(super) struct Transport {
    pub reader: Box<dyn Read + Send>,
    pub writer: Box<dyn DeadlineWriter>,
    pub cancel: Arc<dyn Cancel>,
}

#[cfg(not(target_os = "windows"))]
mod platform {
    use super::*;
    use std::io::Write;
    use std::net::Shutdown;
    use std::os::unix::net::UnixStream;

    impl Cancel for UnixStream {
        fn cancel(&self) {
            let _ = self.shutdown(Shutdown::Both);
        }
    }

    impl DeadlineWriter for UnixStream {
        fn write_until(&mut self, mut bytes: &[u8], deadline: Instant) -> io::Result<()> {
            while !bytes.is_empty() {
                let remaining = deadline.saturating_duration_since(Instant::now());
                if remaining.is_zero() {
                    return Err(io::ErrorKind::TimedOut.into());
                }
                // Poll in short slices so even a blocked socket write notices
                // the independent shutdown promptly on every Unix platform.
                self.set_write_timeout(Some(remaining.min(IO_POLL)))?;
                match self.write(bytes) {
                    Ok(0) => return Err(io::ErrorKind::WriteZero.into()),
                    Ok(n) => bytes = &bytes[n..],
                    Err(e)
                        if matches!(
                            e.kind(),
                            io::ErrorKind::Interrupted
                                | io::ErrorKind::TimedOut
                                | io::ErrorKind::WouldBlock
                        ) =>
                    {
                        continue
                    }
                    Err(e) => return Err(e),
                }
            }
            Ok(())
        }
    }

    pub(crate) fn from_stream(stream: UnixStream) -> io::Result<Transport> {
        stream.set_read_timeout(Some(IO_POLL))?;
        Ok(Transport {
            writer: Box::new(stream.try_clone()?),
            cancel: Arc::new(stream.try_clone()?),
            reader: Box::new(stream),
        })
    }

    pub(crate) fn connect(path: &str) -> io::Result<Transport> {
        from_stream(UnixStream::connect(path)?)
    }
}

#[cfg(target_os = "windows")]
mod platform {
    use super::*;
    use std::cell::UnsafeCell;
    use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
    use windows::core::PCWSTR;
    use windows::Win32::Foundation::{
        CloseHandle, ERROR_IO_PENDING, GENERIC_READ, GENERIC_WRITE, HANDLE,
    };
    use windows::Win32::Storage::FileSystem::{
        CreateFileW, ReadFile, WriteFile, FILE_FLAG_OVERLAPPED, FILE_SHARE_MODE, OPEN_EXISTING,
    };
    use windows::Win32::System::IO::{BindIoCompletionCallback, CancelIoEx, OVERLAPPED};

    struct Pipe(HANDLE);
    // An overlapped pipe supports independent concurrent reads/writes. The handle
    // is immutable and owned until every outstanding completion has released it.
    unsafe impl Send for Pipe {}
    unsafe impl Sync for Pipe {}
    impl Drop for Pipe {
        fn drop(&mut self) {
            unsafe {
                let _ = CloseHandle(self.0);
            }
        }
    }
    impl Cancel for Pipe {
        fn cancel(&self) {
            unsafe {
                let _ = CancelIoEx(self.0, None);
            }
        }
    }

    // OVERLAPPED must be first: the completion callback receives its address.
    // Neither it nor the buffer can be freed on timeout/cancellation: the OS
    // still owns those addresses until it delivers a completion. An extra Arc
    // reference is transferred to the callback, including synchronous success.
    #[repr(C)]
    struct Operation {
        overlapped: UnsafeCell<OVERLAPPED>,
        buffer: UnsafeCell<Vec<u8>>,
        pipe: Arc<Pipe>,
        done: Sender<Completion>,
    }
    struct Completion {
        operation: Arc<Operation>,
        error: u32,
        count: usize,
    }
    // Only the issuing worker accesses buffer/OVERLAPPED before I/O. After
    // issuance the OS owns them; the receiver accesses the buffer only after
    // completion AND after ReadFile/WriteFile returned. The callback only sends
    // status, never touches the buffer. CancelIoEx takes a const operation ptr.
    unsafe impl Send for Operation {}
    unsafe impl Sync for Operation {}

    unsafe extern "system" fn completed(error: u32, count: u32, ptr: *mut OVERLAPPED) {
        let operation = Arc::from_raw(ptr.cast::<Operation>());
        let _ = operation.done.send(Completion {
            operation: operation.clone(),
            error,
            count: count as usize,
        });
    }

    fn issue(
        pipe: &Arc<Pipe>,
        buffer: Vec<u8>,
        write: bool,
    ) -> io::Result<(Arc<Operation>, Receiver<Completion>)> {
        let (done, receiver) = mpsc::channel();
        let operation = Arc::new(Operation {
            overlapped: UnsafeCell::new(OVERLAPPED::default()),
            buffer: UnsafeCell::new(buffer),
            pipe: pipe.clone(),
            done,
        });
        let callback_ref = Arc::into_raw(operation.clone());
        let result = unsafe {
            if write {
                WriteFile(
                    pipe.0,
                    Some(&*operation.buffer.get()),
                    None,
                    Some(operation.overlapped.get()),
                )
            } else {
                ReadFile(
                    pipe.0,
                    Some(&mut *operation.buffer.get()),
                    None,
                    Some(operation.overlapped.get()),
                )
            }
        };
        if let Err(error) = result {
            if error.code() != ERROR_IO_PENDING.to_hresult() {
                // Failed to start: there will be no completion callback.
                unsafe {
                    drop(Arc::from_raw(callback_ref));
                }
                return Err(io::Error::other(error));
            }
        }
        Ok((operation, receiver))
    }

    fn wait(
        receiver: &Receiver<Completion>,
        timeout: std::time::Duration,
    ) -> io::Result<Completion> {
        match receiver.recv_timeout(timeout) {
            Ok(completion) if completion.error == 0 => Ok(completion),
            Ok(completion) => Err(io::Error::from_raw_os_error(completion.error as i32)),
            Err(RecvTimeoutError::Timeout) => Err(io::ErrorKind::TimedOut.into()),
            Err(RecvTimeoutError::Disconnected) => Err(io::ErrorKind::BrokenPipe.into()),
        }
    }

    struct Reader {
        pipe: Arc<Pipe>,
        pending: Option<(Arc<Operation>, Receiver<Completion>)>,
    }
    impl Read for Reader {
        fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
            if bytes.is_empty() {
                return Ok(0);
            }
            if self.pending.is_none() {
                self.pending = Some(issue(&self.pipe, vec![0; bytes.len()], false)?);
            }
            // Keep the SAME read across polling timeouts, otherwise a cancelled
            // read that completed concurrently could silently lose JSON bytes.
            let completion = wait(&self.pending.as_ref().unwrap().1, IO_POLL);
            if matches!(&completion, Err(e) if e.kind() == io::ErrorKind::TimedOut) {
                return Err(io::ErrorKind::TimedOut.into());
            }
            self.pending.take();
            let completion = completion?;
            let data = unsafe { &*completion.operation.buffer.get() };
            let count = completion.count.min(bytes.len());
            bytes[..count].copy_from_slice(&data[..count]);
            Ok(count)
        }
    }

    impl Drop for Reader {
        fn drop(&mut self) {
            if let Some((operation, _)) = &self.pending {
                // Covers a read issued concurrently with connection-wide cancel.
                unsafe {
                    let _ = CancelIoEx(self.pipe.0, Some(operation.overlapped.get()));
                }
            }
        }
    }

    struct Writer(Arc<Pipe>);
    impl DeadlineWriter for Writer {
        fn write_until(&mut self, mut bytes: &[u8], deadline: Instant) -> io::Result<()> {
            while !bytes.is_empty() {
                let remaining = deadline.saturating_duration_since(Instant::now());
                if remaining.is_zero() {
                    return Err(io::ErrorKind::TimedOut.into());
                }
                let (operation, receiver) = issue(&self.0, bytes.to_vec(), true)?;
                match wait(&receiver, remaining) {
                    Ok(completion) if completion.count > 0 => bytes = &bytes[completion.count..],
                    Ok(_) => return Err(io::ErrorKind::WriteZero.into()),
                    Err(error) => {
                        unsafe {
                            let _ = CancelIoEx(self.0 .0, Some(operation.overlapped.get()));
                        }
                        // The callback retains operation and pipe until cancellation
                        // completes. There is no unbounded cancellation wait here.
                        return Err(error);
                    }
                }
            }
            Ok(())
        }
    }

    pub(crate) fn connect(path: &str) -> io::Result<Transport> {
        let wide: Vec<u16> = path.encode_utf16().chain(Some(0)).collect();
        let pipe = Arc::new(Pipe(unsafe {
            CreateFileW(
                PCWSTR(wide.as_ptr()),
                GENERIC_READ.0 | GENERIC_WRITE.0,
                FILE_SHARE_MODE(0),
                None,
                OPEN_EXISTING,
                FILE_FLAG_OVERLAPPED,
                HANDLE::default(),
            )
            .map_err(io::Error::other)?
        }));
        unsafe {
            BindIoCompletionCallback(pipe.0, Some(completed), 0).map_err(io::Error::other)?;
        }
        Ok(Transport {
            reader: Box::new(Reader {
                pipe: pipe.clone(),
                pending: None,
            }),
            writer: Box::new(Writer(pipe.clone())),
            cancel: pipe,
        })
    }
}

pub(super) use platform::connect;
#[cfg(all(test, not(target_os = "windows")))]
pub(super) use platform::from_stream;
