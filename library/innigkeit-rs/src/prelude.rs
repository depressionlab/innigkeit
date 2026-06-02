/// Convenience re-exports for apps that want a single `use
/// innigkeit::prelude::*`.
pub use crate::errno::Errno;
pub use crate::fs::{File, OpenFlags};
pub use crate::io::{read, read_line, write};
pub use crate::net::UdpSocket;
pub use crate::process::{args, exit, getpid, sleep_ms, uptime_ms};
pub use crate::sync::Mutex;
pub use crate::{eprint, eprintln, print, println};
