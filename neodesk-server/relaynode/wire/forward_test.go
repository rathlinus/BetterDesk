package wire

import (
	"bytes"
	"io"
	"testing"
)

// TestForwardTCPHeaderThenRawBytes: the header frame is followed by the
// client's raw bytes on the same stream, and reading the header leaves
// those bytes unread, so central can hand the rest of the stream to the
// signal server as it is.
func TestForwardTCPHeaderThenRawBytes(t *testing.T) {
	var buf bytes.Buffer
	in := ForwardTCP{Service: ServiceSignal, ClientAddr: "10.3.0.5:51000"}
	if err := WriteFrame(&buf, in); err != nil {
		t.Fatal(err)
	}
	raw := []byte{0x00, 0x16, 0x03, 0x01, 0xff, '{', '}'}
	buf.Write(raw)

	f, err := ReadFrame(&buf)
	if err != nil {
		t.Fatal(err)
	}
	var out ForwardTCP
	if f.Type != TypeForwardTCP || f.Decode(&out) != nil || out != in {
		t.Fatalf("got %s %+v, want %+v", f.Type, out, in)
	}
	rest, _ := io.ReadAll(&buf)
	if !bytes.Equal(rest, raw) {
		t.Fatalf("bytes after the header %x, want %x", rest, raw)
	}
}

// TestDatagramCarriesBinaryData: a datagram's bytes survive the JSON
// frame whatever they hold.
func TestDatagramCarriesBinaryData(t *testing.T) {
	var buf bytes.Buffer
	data := []byte{0, 1, 2, 0xff, 0xfe, '"', '\\', '\n'}
	if err := WriteFrame(&buf, Datagram{Addr: "10.3.0.5:40000", Data: data}); err != nil {
		t.Fatal(err)
	}
	f, err := ReadFrame(&buf)
	if err != nil {
		t.Fatal(err)
	}
	var d Datagram
	if f.Type != TypeDatagram || f.Decode(&d) != nil || d.Addr != "10.3.0.5:40000" || !bytes.Equal(d.Data, data) {
		t.Fatalf("got %s %+v", f.Type, d)
	}
}

func TestParseClientAddr(t *testing.T) {
	for _, ok := range []string{"10.3.0.5:51000", "192.168.1.20:1", "203.0.113.7:21116", "[fd00::5]:4000", "[::ffff:10.0.0.1]:80"} {
		if _, err := ParseClientAddr(ok); err != nil {
			t.Errorf("%s: %v", ok, err)
		}
	}
	if ap, _ := ParseClientAddr("[::ffff:10.0.0.1]:80"); ap.String() != "10.0.0.1:80" {
		t.Errorf("mapped address kept as %s, want 10.0.0.1:80", ap)
	}
	// Loopback matters most: the API treats loopback callers as this
	// machine
	for _, bad := range []string{"127.0.0.1:5000", "[::1]:5000", "0.0.0.0:5000", "10.0.0.1:0", "224.0.0.1:5000",
		"255.255.255.255:5000", "10.0.0.1", "host:5000", ""} {
		if _, err := ParseClientAddr(bad); err == nil {
			t.Errorf("%q accepted", bad)
		}
	}
}

func TestValidService(t *testing.T) {
	for _, s := range []string{ServiceSignal, ServiceNAT, ServiceWS, ServiceAPI} {
		if !ValidService(s) {
			t.Errorf("%s refused", s)
		}
	}
	for _, s := range []string{"", "relay", "control", "SIGNAL"} {
		if ValidService(s) {
			t.Errorf("%q accepted", s)
		}
	}
}
