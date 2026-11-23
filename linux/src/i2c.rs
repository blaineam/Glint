//! DDC/CI and EDID over `/dev/i2c-N` (the kernel's i2c-dev interface). Access needs the
//! i2c-dev module and permission on the device node, which `glint setup` (or the package)
//! grants to the logged-in user; Raspberry Pi OS users are usually in the `i2c` group.

use std::fs::{File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::thread::sleep;
use std::time::{Duration, Instant};

use crate::proto::{self, ReplyError, VcpReply, DDC_ADDR, EDID_ADDR};

const I2C_SLAVE: u64 = 0x0703;
/// DDC/CI asks hosts to wait 40 ms before reading a reply, and to leave ~50 ms between
/// transactions.
const REPLY_DELAY: Duration = Duration::from_millis(40);
const GAP: Duration = Duration::from_millis(50);

pub struct Bus {
    pub number: u32,
    file: File,
    last: Option<Instant>,
}

impl Bus {
    pub fn open(number: u32) -> io::Result<Bus> {
        let file = OpenOptions::new().read(true).write(true).open(format!("/dev/i2c-{number}"))?;
        Ok(Bus { number, file, last: None })
    }

    fn address(&self, addr: u16) -> io::Result<()> {
        // SAFETY: I2C_SLAVE takes the 7-bit address by value.
        let rc = unsafe { libc::ioctl(self.file.as_raw_fd(), I2C_SLAVE as _, addr as libc::c_ulong) };
        if rc < 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok(())
        }
    }

    fn pace(&mut self) {
        if let Some(t) = self.last {
            let since = t.elapsed();
            if since < GAP {
                sleep(GAP - since);
            }
        }
    }

    fn done(&mut self) {
        self.last = Some(Instant::now());
    }

    /// Reads a VCP feature, retrying on the null message and on noise.
    pub fn get_vcp(&mut self, vcp: u8) -> Result<VcpReply, ReplyError> {
        let mut last = ReplyError::Malformed;
        for _ in 0..3 {
            self.pace();
            let attempt = (|| {
                self.address(DDC_ADDR).ok()?;
                self.file.write_all(&proto::get_vcp_request(vcp)).ok()?;
                sleep(REPLY_DELAY);
                let mut buf = [0u8; 11];
                self.file.read_exact(&mut buf).ok()?;
                Some(buf)
            })();
            self.done();
            match attempt.map(|b| proto::parse_get_vcp_reply(&b, vcp)) {
                Some(Ok(r)) => return Ok(r),
                Some(Err(ReplyError::Unsupported)) => return Err(ReplyError::Unsupported),
                Some(Err(e)) => last = e,
                None => last = ReplyError::Malformed,
            }
        }
        Err(last)
    }

    /// Writes a VCP feature. True if the bus accepted it (not proof the monitor applied it).
    pub fn set_vcp(&mut self, vcp: u8, value: u16) -> bool {
        for _ in 0..2 {
            self.pace();
            let ok = self.address(DDC_ADDR).is_ok() && self.file.write_all(&proto::set_vcp_request(vcp, value)).is_ok();
            self.done();
            if ok {
                return true;
            }
        }
        false
    }

    /// The monitor's EDID base block, read from the EEPROM at 0x50 (used to match buses to
    /// monitors when the driver doesn't link them, e.g. NVIDIA's proprietary driver).
    pub fn read_edid(&mut self) -> Option<Vec<u8>> {
        self.pace();
        let r = (|| {
            self.address(EDID_ADDR).ok()?;
            self.file.write_all(&[0]).ok()?;
            let mut buf = vec![0u8; 128];
            self.file.read_exact(&mut buf).ok()?;
            Some(buf)
        })();
        self.done();
        r
    }
}
