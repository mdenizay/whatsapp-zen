//! Re-wraps the Opus packets of a Core Audio Format file (what macOS records)
//! into the Ogg Opus stream WhatsApp wants for voice messages. No audio is
//! re-encoded; only the container changes.

fn be32(bytes: &[u8]) -> u32 {
    u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]])
}

fn be64(bytes: &[u8]) -> u64 {
    u64::from_be_bytes(bytes[..8].try_into().expect("eight bytes"))
}

pub fn caf_opus_to_ogg(caf: &[u8]) -> Result<Vec<u8>, String> {
    if caf.len() < 8 || &caf[..4] != b"caff" {
        return Err("not a CAF file".into());
    }
    let (mut desc, mut pakt, mut data): (&[u8], &[u8], Option<&[u8]>) = (&[], &[], None);
    let mut pos = 8;
    while pos + 12 <= caf.len() {
        let kind = &caf[pos..pos + 4];
        let size = be64(&caf[pos + 4..pos + 12]) as i64;
        let start = pos + 12;
        // A size of -1 means "to the end of the file".
        let end = if size >= 0 && start + size as usize <= caf.len() { start + size as usize } else { caf.len() };
        match kind {
            b"desc" => desc = &caf[start..end],
            b"pakt" => pakt = &caf[start..end],
            // The data chunk starts with an edit count.
            b"data" if end - start >= 4 => data = Some(&caf[start + 4..end]),
            _ => {}
        }
        pos = end;
    }
    let Some(data) = data.filter(|_| desc.len() >= 32 && pakt.len() >= 24) else {
        return Err("incomplete CAF file".into());
    };
    if &desc[8..12] != b"opus" {
        return Err("recording is not Opus".into());
    }
    let bytes_per_packet = be32(&desc[16..20]) as usize;
    let mut frames_per_packet = be32(&desc[20..24]) as u64;
    let mut channels = be32(&desc[24..28]);
    let packets = be64(&pakt[0..8]) as usize;
    let mut priming = be32(&pakt[16..20]) as i32;
    if frames_per_packet == 0 {
        frames_per_packet = 960; // 20 ms at 48 kHz
    }
    if !(1..=2).contains(&channels) {
        channels = 1;
    }
    if priming <= 0 {
        priming = 312;
    }

    // The packet table holds each packet's size as a base-128 varint.
    let mut table = &pakt[24..];
    let mut sizes = Vec::with_capacity(packets);
    while sizes.len() < packets {
        if bytes_per_packet > 0 {
            sizes.push(bytes_per_packet);
            continue;
        }
        let mut n = 0usize;
        loop {
            let Some((&byte, rest)) = table.split_first() else { return Err("truncated packet table".into()) };
            table = rest;
            n = n << 7 | (byte & 0x7f) as usize;
            if byte & 0x80 == 0 {
                break;
            }
        }
        sizes.push(n);
    }
    if sizes.is_empty() {
        return Err("empty recording".into());
    }

    let mut out = Vec::new();
    let mut sequence = 0u32;
    let mut page = |header_type: u8, granule: u64, packets: &[&[u8]]| {
        let mut segments = Vec::new();
        let mut body = Vec::new();
        for packet in packets {
            let mut n = packet.len();
            while n >= 255 {
                segments.push(255u8);
                n -= 255;
            }
            segments.push(n as u8);
            body.extend_from_slice(packet);
        }
        let mut header = vec![0u8; 27];
        header[..4].copy_from_slice(b"OggS");
        header[5] = header_type;
        header[6..14].copy_from_slice(&granule.to_le_bytes());
        header[14..18].copy_from_slice(&0x5741_4e41u32.to_le_bytes());
        header[18..22].copy_from_slice(&sequence.to_le_bytes());
        header[26] = segments.len() as u8;
        header.extend_from_slice(&segments);
        header.extend_from_slice(&body);
        let crc = crc(&header);
        header[22..26].copy_from_slice(&crc.to_le_bytes());
        out.extend_from_slice(&header);
        sequence += 1;
    };

    let mut head = vec![0u8; 19];
    head[..8].copy_from_slice(b"OpusHead");
    head[8] = 1;
    head[9] = channels as u8;
    head[10..12].copy_from_slice(&(priming as u16).to_le_bytes());
    head[12..16].copy_from_slice(&48000u32.to_le_bytes());
    page(0x02, 0, &[&head]);
    let mut tags = b"OpusTags".to_vec();
    tags.extend_from_slice(&8u32.to_le_bytes());
    tags.extend_from_slice(b"WhatsApp");
    tags.extend_from_slice(&0u32.to_le_bytes());
    page(0x00, 0, &[&tags]);

    // One second of audio per page: up to 50 packets of 20 ms, kept under the
    // 255-segment limit of a page.
    let mut batch: Vec<&[u8]> = Vec::new();
    let (mut segments, mut granule, mut offset) = (0usize, 0u64, 0usize);
    for (index, &size) in sizes.iter().enumerate() {
        if offset + size > data.len() {
            return Err("truncated audio data".into());
        }
        let need = size / 255 + 1;
        if batch.len() == 50 || segments + need > 255 {
            page(0x00, granule, &batch);
            batch.clear();
            segments = 0;
        }
        batch.push(&data[offset..offset + size]);
        segments += need;
        offset += size;
        granule += frames_per_packet;
        if index == sizes.len() - 1 {
            page(0x04, granule, &batch);
        }
    }
    Ok(out)
}

/// Ogg's CRC-32 (polynomial 0x04c11db7, no reflection), computed over a page
/// whose checksum field is still zero.
fn crc(page: &[u8]) -> u32 {
    let mut crc = 0u32;
    for &byte in page {
        let mut r = (((crc >> 24) as u8 ^ byte) as u32) << 24;
        for _ in 0..8 {
            r = if r & 0x8000_0000 != 0 { r << 1 ^ 0x04c1_1db7 } else { r << 1 };
        }
        crc = crc << 8 ^ r;
    }
    crc
}
