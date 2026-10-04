package main

import (
	"bytes"
	"encoding/binary"
	"errors"
)

// cafOpusToOgg re-wraps Opus packets from a Core Audio Format file into an
// Ogg Opus stream. No audio is re-encoded; only the container changes.
func cafOpusToOgg(caf []byte) ([]byte, error) {
	if len(caf) < 8 || string(caf[:4]) != "caff" {
		return nil, errors.New("not a CAF file")
	}
	var (
		desc, pakt, data []byte
		pos              = 8
	)
	for pos+12 <= len(caf) {
		kind := string(caf[pos : pos+4])
		size := int64(binary.BigEndian.Uint64(caf[pos+4 : pos+12]))
		start := pos + 12
		end := len(caf)
		if size >= 0 && start+int(size) <= len(caf) {
			end = start + int(size) // size -1 means "to end of file"
		}
		switch kind {
		case "desc":
			desc = caf[start:end]
		case "pakt":
			pakt = caf[start:end]
		case "data":
			if end-start >= 4 {
				data = caf[start+4 : end] // skip the edit count
			}
		}
		pos = end
	}
	if len(desc) < 32 || len(pakt) < 24 || data == nil {
		return nil, errors.New("incomplete CAF file")
	}
	if string(desc[8:12]) != "opus" {
		return nil, errors.New("recording is not Opus")
	}
	bytesPerPacket := int(binary.BigEndian.Uint32(desc[16:20]))
	framesPerPacket := int(binary.BigEndian.Uint32(desc[20:24]))
	channels := int(binary.BigEndian.Uint32(desc[24:28]))
	packets := int(binary.BigEndian.Uint64(pakt[0:8]))
	priming := int(int32(binary.BigEndian.Uint32(pakt[16:20])))
	if framesPerPacket == 0 {
		framesPerPacket = 960 // 20 ms at 48 kHz
	}
	if channels < 1 || channels > 2 {
		channels = 1
	}
	if priming <= 0 {
		priming = 312
	}

	// The packet table holds each packet's size as a base-128 varint.
	table := pakt[24:]
	sizes := make([]int, 0, packets)
	for len(sizes) < packets {
		if bytesPerPacket > 0 {
			sizes = append(sizes, bytesPerPacket)
			continue
		}
		n := 0
		for {
			if len(table) == 0 {
				return nil, errors.New("truncated packet table")
			}
			b := table[0]
			table = table[1:]
			n = n<<7 | int(b&0x7f)
			if b&0x80 == 0 {
				break
			}
		}
		sizes = append(sizes, n)
	}

	var out bytes.Buffer
	const serial = 0x57414e41
	seq := uint32(0)
	page := func(headerType byte, granule uint64, pkts [][]byte) {
		var segs []byte
		var body []byte
		for _, p := range pkts {
			n := len(p)
			for n >= 255 {
				segs = append(segs, 255)
				n -= 255
			}
			segs = append(segs, byte(n))
			body = append(body, p...)
		}
		h := make([]byte, 27, 27+len(segs)+len(body))
		copy(h, "OggS")
		h[5] = headerType
		binary.LittleEndian.PutUint64(h[6:], granule)
		binary.LittleEndian.PutUint32(h[14:], serial)
		binary.LittleEndian.PutUint32(h[18:], seq)
		h[26] = byte(len(segs))
		h = append(append(h, segs...), body...)
		binary.LittleEndian.PutUint32(h[22:], oggCRC(h))
		out.Write(h)
		seq++
	}

	head := make([]byte, 19)
	copy(head, "OpusHead")
	head[8] = 1
	head[9] = byte(channels)
	binary.LittleEndian.PutUint16(head[10:], uint16(priming))
	binary.LittleEndian.PutUint32(head[12:], 48000)
	page(0x02, 0, [][]byte{head})

	tags := []byte("OpusTags")
	tags = binary.LittleEndian.AppendUint32(tags, 8)
	tags = append(tags, "WhatsApp"...)
	tags = binary.LittleEndian.AppendUint32(tags, 0)
	page(0x00, 0, [][]byte{tags})

	// One second of audio per page: up to 50 packets of 20 ms, kept under the
	// 255-segment limit of a page.
	var batch [][]byte
	segments, granule, offset := 0, uint64(0), 0
	for i, size := range sizes {
		if offset+size > len(data) {
			return nil, errors.New("truncated audio data")
		}
		need := size/255 + 1
		if len(batch) == 50 || segments+need > 255 {
			page(0x00, granule, batch)
			batch, segments = nil, 0
		}
		batch = append(batch, data[offset:offset+size])
		segments += need
		offset += size
		granule += uint64(framesPerPacket)
		if i == len(sizes)-1 {
			page(0x04, granule, batch)
		}
	}
	if len(sizes) == 0 {
		return nil, errors.New("empty recording")
	}
	return out.Bytes(), nil
}

var oggCRCTable = func() (t [256]uint32) {
	for i := range t {
		r := uint32(i) << 24
		for j := 0; j < 8; j++ {
			if r&0x80000000 != 0 {
				r = r<<1 ^ 0x04c11db7
			} else {
				r <<= 1
			}
		}
		t[i] = r
	}
	return
}()

// oggCRC is Ogg's CRC-32 (polynomial 0x04c11db7, no reflection), computed
// over a page whose checksum field is still zero.
func oggCRC(page []byte) uint32 {
	var crc uint32
	for _, b := range page {
		crc = crc<<8 ^ oggCRCTable[byte(crc>>24)^b]
	}
	return crc
}
