#!/usr/bin/env python3
"""
Replay ustreamer's V4L2 M2M H.264 encoder sequence, ioctl for ioctl, against
whatever device is given on the command line - in practice the libv4l-rkmpp
plugin's dummy device, reached through an LD_PRELOAD of libv4l's
v4l2convert.so.

    usage: ustreamer-m2m-probe.py <device> <width> <height> <in-fourcc>
                                  [frames] [output.h264]

The point is to answer "would ustreamer drive this shim?" without needing a
working capture chain: the sequence, the argument values and the order come
from ustreamer 6.65's src/ustreamer/m2m.c, so a step that fails here is a step
that would have failed there.

Every ioctl is reported. A rejected S_CTRL does not stop the run even though
ustreamer would abort on it, because the interesting question after that is
whether the data path works at all - so one pass tells you both things.

This used to carry two deliberate deviations from ustreamer, both worked
around rather than fixed: the CAPTURE buffer had to be drained before the
INPUT one, and re-queued before the INPUT one was released. Both were the
same deadlock, and it is fixed in patches/libv4l-rkmpp/0002 - the encoder
thread no longer takes the CAPTURE buffer for a separate SPS/PPS when the
client asked for inline headers. So the order below is now ustreamer's
order, exactly, and a run that completes is a run ustreamer would have
completed. See docs/roadmap.md.
"""
import ctypes, ctypes.util, os, select, struct, sys, time

libc = ctypes.CDLL(None, use_errno=True)
libc.ioctl.argtypes = [ctypes.c_int, ctypes.c_ulong, ctypes.c_void_p]
libc.mmap.restype = ctypes.c_void_p
libc.mmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int,
                      ctypes.c_int, ctypes.c_int, ctypes.c_long]

VIDIOC_QUERYCAP  = 0x80685600
VIDIOC_S_FMT     = 0xc0d05605
VIDIOC_S_CTRL    = 0xc008561c
VIDIOC_S_PARM    = 0xc0cc5616
VIDIOC_REQBUFS   = 0xc0145608
VIDIOC_QUERYBUF  = 0xc0585609
VIDIOC_QBUF      = 0xc058560f
VIDIOC_DQBUF     = 0xc0585611
VIDIOC_STREAMON  = 0x40045612
VIDIOC_STREAMOFF = 0x40045613

CID_BITRATE       = 0x009909cf
CID_I_PERIOD      = 0x00990a66
CID_PROFILE       = 0x00990a6b
CID_LEVEL         = 0x00990a67
CID_REPEAT_SEQ    = 0x009909e2
CID_MIN_QP        = 0x00990a61
CID_MAX_QP        = 0x00990a62
PROFILE_CONSTRAINED_BASELINE = 1
LEVEL_4_0                    = 11

FOURCC = {n: struct.unpack("<I", n.encode())[0]
          for n in ("H264", "UYVY", "NV12", "YUYV", "YU12")}

TYPE_OUT = 10   # V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE
TYPE_CAP = 9    # V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE
MEM_MMAP = 1
COLORSPACE_JPEG = 7
PROT_RW, MAP_SHARED = 3, 1

fails = []

def io(fd, req, buf, what):
    rc = libc.ioctl(fd, req, ctypes.addressof(buf) if not isinstance(buf, int) else buf)
    if rc < 0:
        e = ctypes.get_errno()
        print("  FAIL %-34s %s (errno %d)" % (what, os.strerror(e), e))
        fails.append(what)
        return False
    print("  ok   %s" % what)
    return True

def fmt_mplane(t, w, h, pixfmt, colorspace, sizeimage=0):
    b = bytearray(208)
    struct.pack_into("<I", b, 0, t)
    struct.pack_into("<IIII", b, 8, w, h, pixfmt, 0)   # w, h, pixelformat, field=ANY
    struct.pack_into("<I", b, 24, colorspace)
    struct.pack_into("<I", b, 28, sizeimage)           # plane_fmt[0].sizeimage
    b[188] = 1                                         # num_planes
    return (ctypes.c_char * 208).from_buffer(b)

def main():
    path = sys.argv[1]
    w, h = int(sys.argv[2]), int(sys.argv[3])
    in_fmt = sys.argv[4]
    nframes = int(sys.argv[5]) if len(sys.argv) > 5 else 30
    out_path = sys.argv[6] if len(sys.argv) > 6 else "/tmp/probe.h264"

    fd = os.open(path, os.O_RDWR)
    print("opened %s -> fd %d" % (path, fd))

    cap = (ctypes.c_char * 104)()
    if io(fd, VIDIOC_QUERYCAP, cap, "QUERYCAP"):
        raw = bytes(cap)
        d = lambda s: s.split(b"\0")[0].decode()
        dcaps = struct.unpack_from("<I", raw, 88)[0]
        print("       driver=%s card=%s device_caps=0x%08x%s" % (
            d(raw[0:16]), d(raw[16:48]), dcaps,
            "  M2M_MPLANE" if dcaps & 0x00004000 else ""))

    print("\n-- controls, in ustreamer's order --")
    for cid, val, name in (
        (CID_BITRATE,    5000 * 1000, "S_CTRL BITRATE"),
        (CID_I_PERIOD,   30,          "S_CTRL H264_I_PERIOD"),
        (CID_PROFILE,    PROFILE_CONSTRAINED_BASELINE, "S_CTRL H264_PROFILE"),
        (CID_LEVEL,      LEVEL_4_0,   "S_CTRL H264_LEVEL"),
        (CID_REPEAT_SEQ, 1,           "S_CTRL REPEAT_SEQ_HEADER"),
        (CID_MIN_QP,     16,          "S_CTRL H264_MIN_QP"),
        (CID_MAX_QP,     32,          "S_CTRL H264_MAX_QP"),
    ):
        ctl = (ctypes.c_char * 8).from_buffer(bytearray(struct.pack("<Ii", cid, val)))
        io(fd, VIDIOC_S_CTRL, ctl, name)

    print("\n-- formats --")
    f = fmt_mplane(TYPE_OUT, w, h, FOURCC[in_fmt], COLORSPACE_JPEG)
    io(fd, VIDIOC_S_FMT, f, "S_FMT OUTPUT_MPLANE (%s in)" % in_fmt)
    got = struct.unpack_from("<I", bytes(f), 16)[0]
    print("       negotiated input fourcc = %s" % struct.pack("<I", got).decode(errors="replace"))

    f = fmt_mplane(TYPE_CAP, w, h, FOURCC["H264"], 0, (1024 + 512) << 10)
    io(fd, VIDIOC_S_FMT, f, "S_FMT CAPTURE_MPLANE (H264 out)")
    got = struct.unpack_from("<I", bytes(f), 16)[0]
    if got != FOURCC["H264"]:
        print("       FAIL: capture fourcc came back %s, not H264" %
              struct.pack("<I", got).decode(errors="replace"))
        fails.append("H264 not negotiable")

    parm = bytearray(204)
    struct.pack_into("<I", parm, 0, TYPE_OUT)
    struct.pack_into("<II", parm, 12, 1, 30)   # parm.output.timeperframe = 1/30
    io(fd, VIDIOC_S_PARM, (ctypes.c_char * 204).from_buffer(parm), "S_PARM 30fps")

    print("\n-- buffers --")
    maps = {}
    for t, name in ((TYPE_OUT, "INPUT"), (TYPE_CAP, "OUTPUT")):
        req = bytearray(struct.pack("<III", 1, t, MEM_MMAP) + b"\0" * 8)
        rb = (ctypes.c_char * 20).from_buffer(req)
        if not io(fd, VIDIOC_REQBUFS, rb, "REQBUFS %s count=1" % name):
            continue
        count = struct.unpack_from("<I", bytes(rb), 0)[0]
        print("       got %d %s buffer(s)" % (count, name))
        plane = (ctypes.c_char * 64)()
        buf = bytearray(88)
        struct.pack_into("<II", buf, 0, 0, t)          # index, type
        struct.pack_into("<I", buf, 60, MEM_MMAP)
        struct.pack_into("<Q", buf, 64, ctypes.addressof(plane))
        struct.pack_into("<I", buf, 72, 1)             # length = n planes
        bb = (ctypes.c_char * 88).from_buffer(buf)
        if not io(fd, VIDIOC_QUERYBUF, bb, "QUERYBUF %s" % name):
            continue
        plen, poff = struct.unpack_from("<I", bytes(plane), 4)[0], struct.unpack_from("<Q", bytes(plane), 8)[0]
        print("       plane length=%d mem_offset=0x%x" % (plen, poff))
        addr = libc.mmap(None, plen, PROT_RW, MAP_SHARED, fd, poff)
        if addr in (None, ctypes.c_void_p(-1).value, 2**64 - 1):
            print("  FAIL mmap %s: %s" % (name, os.strerror(ctypes.get_errno())))
            fails.append("mmap %s" % name)
            continue
        print("  ok   mmap %s at 0x%x" % (name, addr))
        maps[t] = (addr, plen, plane, bb)
        # ustreamer queues every buffer on both queues at init, INPUT
        # included, and then dequeues an INPUT buffer at the top of each
        # frame to get one to fill. Copying that matters: it is what puts
        # the INPUT queue in the state the encoder thread sees.
        io(fd, VIDIOC_QBUF, bb, "QBUF %s" % name)

    print("\n-- streamon --")
    for t, name in ((TYPE_OUT, "INPUT"), (TYPE_CAP, "OUTPUT")):
        ty = (ctypes.c_char * 4).from_buffer(bytearray(struct.pack("<I", t)))
        io(fd, VIDIOC_STREAMON, ty, "STREAMON %s" % name)

    hard = [f for f in fails if not f.startswith("S_CTRL")]
    if hard:
        print("\n-- not encoding: %d step(s) already failed --" % len(hard))
        return 1
    if fails:
        print("\n-- %d S_CTRL(s) rejected; ustreamer would have aborted here."
              " Encoding anyway to test the data path --" % len(fails))
    if TYPE_OUT not in maps or TYPE_CAP not in maps:
        print("\n-- not encoding: buffers were not mapped --")
        return 1

    print("\n-- encoding %d frames --" % nframes)
    bpp = 2 if in_fmt in ("UYVY", "YUYV") else 1.5
    used = int(w * h * bpp)
    src = bytes(bytearray((i * 7 + j) & 0xff for i in range(64) for j in range(64)))
    src = (src * (used // len(src) + 1))[:used]
    in_addr, in_len, in_plane, in_bb = maps[TYPE_OUT]
    out_addr, out_len, out_plane, out_bb = maps[TYPE_CAP]
    got = 0
    t0 = time.monotonic()
    def buf_for(t, plane):
        b = bytearray(88)
        struct.pack_into("<II", b, 0, 0, t)
        struct.pack_into("<I", b, 60, MEM_MMAP)
        struct.pack_into("<Q", b, 64, ctypes.addressof(plane))
        struct.pack_into("<I", b, 72, 1)
        return (ctypes.c_char * 88).from_buffer(b)

    qb = buf_for(TYPE_OUT, in_plane)
    db = buf_for(TYPE_CAP, out_plane)
    poller = select.poll()
    poller.register(fd, select.POLLIN)

    with open(out_path, "wb") as out:
        for n in range(nframes):
            # 1. Take a free INPUT buffer. Everything was queued at init, so
            #    on the first pass this returns immediately.
            if libc.ioctl(fd, VIDIOC_DQBUF, ctypes.addressof(qb)) < 0:
                print("  FAIL DQBUF INPUT frame %d: %s" % (n, os.strerror(ctypes.get_errno())))
                return 1

            # 2. Fill it and send it.
            ctypes.memmove(in_addr, src, min(used, in_len))
            ts_s, ts_us = int(time.monotonic()), n * 1000
            struct.pack_into("<II", in_plane, 0, used, used)   # bytesused, length
            struct.pack_into("<qq", qb, 24, ts_s, ts_us)
            if libc.ioctl(fd, VIDIOC_QBUF, ctypes.addressof(qb)) < 0:
                print("  FAIL QBUF INPUT frame %d: %s" % (n, os.strerror(ctypes.get_errno())))
                return 1

            # 3. Wait for the encoder, with the same one-second budget
            #    ustreamer gives it. A timeout here is the deadlock coming
            #    back, so say so rather than blocking forever in DQBUF.
            if not poller.poll(1000):
                print("  FAIL poll frame %d: encoder produced nothing in 1s" % n)
                return 1

            # 4. Collect the packet, then recycle the buffer.
            if libc.ioctl(fd, VIDIOC_DQBUF, ctypes.addressof(db)) < 0:
                print("  FAIL DQBUF OUTPUT frame %d: %s" % (n, os.strerror(ctypes.get_errno())))
                return 1
            nbytes = struct.unpack_from("<I", bytes(out_plane), 0)[0]
            flags = struct.unpack_from("<I", bytes(db), 12)[0]
            out.write(ctypes.string_at(out_addr, nbytes))
            got += 1
            if n < 3 or n == nframes - 1:
                print("  frame %-3d %7d bytes  flags=0x%08x%s" % (
                    n, nbytes, flags, "  KEY" if flags & 0x8 else ""))
            if libc.ioctl(fd, VIDIOC_QBUF, ctypes.addressof(db)) < 0:
                print("  FAIL QBUF OUTPUT frame %d: %s" % (n, os.strerror(ctypes.get_errno())))
                return 1
    dt = time.monotonic() - t0
    print("\n  %d frames in %.2fs = %.1f fps -> %s (%d bytes)" % (
        got, dt, got / dt, out_path, os.path.getsize(out_path)))
    return 0

sys.exit(main())
