//! DDC/CI packet framing (VESA DDC/CI 1.1, MCCS). Glint speaks it directly over the
//! monitor's I²C bus (`/dev/i2c-N`, slave address 0x37), the same channel the monitor's own
//! buttons and the Mac app use. Pure functions: built and checked here, sent by `i2c`.

/// I²C slave address of a monitor's DDC/CI endpoint.
pub const DDC_ADDR: u16 = 0x37;
/// I²C slave address of the EDID EEPROM.
pub const EDID_ADDR: u16 = 0x50;

/// The host's source address byte, and the destination byte (0x6E = 0x37 << 1) that the
/// request checksum starts from.
const HOST: u8 = 0x51;
const DEST: u8 = 0x6E;
/// Replies are checksummed from the virtual host address 0x50.
const REPLY_SEED: u8 = 0x50;

const OP_GET_VCP: u8 = 0x01;
const OP_GET_VCP_REPLY: u8 = 0x02;
const OP_SET_VCP: u8 = 0x03;

fn checksum(seed: u8, bytes: &[u8]) -> u8 {
    bytes.iter().fold(seed, |acc, b| acc ^ b)
}

/// "Get VCP feature" request for `vcp` (e.g. 0x10 brightness, 0x62 volume).
pub fn get_vcp_request(vcp: u8) -> [u8; 5] {
    let mut p = [HOST, 0x80 | 2, OP_GET_VCP, vcp, 0];
    p[4] = checksum(DEST, &p[..4]);
    p
}

/// "Set VCP feature" request.
pub fn set_vcp_request(vcp: u8, value: u16) -> [u8; 7] {
    let [hi, lo] = value.to_be_bytes();
    let mut p = [HOST, 0x80 | 4, OP_SET_VCP, vcp, hi, lo, 0];
    p[6] = checksum(DEST, &p[..6]);
    p
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct VcpReply {
    pub current: u16,
    pub max: u16,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ReplyError {
    /// The monitor sent the DDC "null message": busy, try again.
    Null,
    /// The monitor says it doesn't support this VCP code.
    Unsupported,
    /// Wrong length, opcode, VCP code or checksum (noise on the bus, or not a monitor).
    Malformed,
}

/// Parses the 11 bytes read back after a Get VCP request.
pub fn parse_get_vcp_reply(buf: &[u8], vcp: u8) -> Result<VcpReply, ReplyError> {
    if buf.len() >= 3 && buf[1] == 0x80 {
        return Err(ReplyError::Null);
    }
    if buf.len() < 11 || buf[1] != 0x88 || buf[2] != OP_GET_VCP_REPLY {
        return Err(ReplyError::Malformed);
    }
    if checksum(REPLY_SEED, &buf[..10]) != buf[10] {
        return Err(ReplyError::Malformed);
    }
    if buf[3] != 0 {
        return Err(ReplyError::Unsupported);
    }
    if buf[4] != vcp {
        return Err(ReplyError::Malformed);
    }
    Ok(VcpReply { max: u16::from_be_bytes([buf[6], buf[7]]), current: u16::from_be_bytes([buf[8], buf[9]]) })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn get_request_matches_the_spec() {
        // The canonical "get brightness" packet: 6E 51 82 01 10 AC (6E is the address).
        assert_eq!(get_vcp_request(0x10), [0x51, 0x82, 0x01, 0x10, 0xAC]);
    }

    #[test]
    fn set_request_checksums() {
        let p = set_vcp_request(0x10, 50);
        assert_eq!(&p[..6], &[0x51, 0x84, 0x03, 0x10, 0x00, 0x32]);
        assert_eq!(p[6], [0x6E, 0x51, 0x84, 0x03, 0x10, 0x00, 0x32].iter().fold(0u8, |a, b| a ^ b));
        let big = set_vcp_request(0x62, 0x0102);
        assert_eq!(&big[4..6], &[0x01, 0x02]);
    }

    fn reply(result: u8, vcp: u8, max: u16, cur: u16) -> Vec<u8> {
        let mut b = vec![0x6E, 0x88, 0x02, result, vcp, 0x00];
        b.extend_from_slice(&max.to_be_bytes());
        b.extend_from_slice(&cur.to_be_bytes());
        b.push(checksum(0x50, &b));
        b
    }

    #[test]
    fn parses_replies() {
        assert_eq!(parse_get_vcp_reply(&reply(0, 0x10, 100, 46), 0x10), Ok(VcpReply { current: 46, max: 100 }));
        assert_eq!(parse_get_vcp_reply(&reply(1, 0x62, 0, 0), 0x62), Err(ReplyError::Unsupported));
        assert_eq!(parse_get_vcp_reply(&reply(0, 0x12, 100, 50), 0x10), Err(ReplyError::Malformed));
        let mut bad = reply(0, 0x10, 100, 46);
        bad[10] ^= 1;
        assert_eq!(parse_get_vcp_reply(&bad, 0x10), Err(ReplyError::Malformed));
        assert_eq!(parse_get_vcp_reply(&[0x6E, 0x80, 0xBE], 0x10), Err(ReplyError::Null));
        assert_eq!(parse_get_vcp_reply(&[0xFF; 11], 0x10), Err(ReplyError::Malformed));
        assert_eq!(parse_get_vcp_reply(&[], 0x10), Err(ReplyError::Malformed));
    }
}
